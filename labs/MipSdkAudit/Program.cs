using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.Identity.Client;
using Microsoft.Identity.Client.Broker;
using Microsoft.InformationProtection;
using Microsoft.InformationProtection.File;
using Microsoft.InformationProtection.Policy;
using Microsoft.InformationProtection.Policy.Actions;

if (args is ["--help"] or [])
{
    Console.WriteLine("MipSdkAudit <tenant-guid> <client-guid> <test-user-upn> [sit-guid]");
    Console.WriteLine("MipSdkAudit --check-sso <config.json>");
    Console.WriteLine("MipSdkAudit --config <config.json> --audit-log <inventory.jsonl>");
    Console.WriteLine("MipSdkAudit --list-office-labels <config.json>");
    Console.WriteLine("MipSdkAudit --apply-office-copy <config.json> <source> <output> <label-guid>");
    Console.WriteLine("MipSdkAudit --self-test");
    return 0;
}

bool selfTest = args is ["--self-test"];
bool checkSso = args is ["--check-sso", _];
bool auditLog = args is ["--config", _, "--audit-log", _];
bool listOfficeLabels = args is ["--list-office-labels", _];
bool applyOfficeCopy = args is ["--apply-office-copy", _, _, _, _];
bool silentMode = checkSso || auditLog || listOfficeLabels || applyOfficeCopy;
Guid tenantId = default, clientId = default, sitId = default;
if (!selfTest && !silentMode && (args.Length is < 3 or > 4 ||
    !Guid.TryParse(args[0], out tenantId) || tenantId == Guid.Empty ||
    !Guid.TryParse(args[1], out clientId) || clientId == Guid.Empty ||
    !args[2].Contains('@') || args[2].Any(char.IsWhiteSpace) ||
    (args.Length == 4 && (!Guid.TryParse(args[3], out sitId) || sitId == Guid.Empty))))
{
    Console.Error.WriteLine("Expected tenant and client GUIDs, a test user UPN, and optionally a lab SIT GUID. See --help.");
    return 2;
}

if (!OperatingSystem.IsWindows() || RuntimeInformation.ProcessArchitecture != Architecture.X64)
{
    Console.Error.WriteLine("This lab requires Windows with an x64 .NET process.");
    return 2;
}

var stage = "readConfiguration";
DirectoryInfo? fixture = null;
LabAuth? auth = null;
LabConsent? consent = null;
try
{
    AuditSettings? settings = silentMode ? AuditSettings.Read(args[1]) : null;
    stage = "validateOfficeCopy";
    OfficeLabelCopy? officeCopy = applyOfficeCopy
        ? OfficeLabelCopy.Prepare(settings!, args[2], args[3], args[4]) : null;
    stage = "readAuditLog";
    List<AuditCandidate> candidates = auditLog ? AuditCandidate.ReadLog(args[3], settings!) : [];
    if (auditLog && candidates.Count == 0)
    {
        Emit(new { @event = "auditSummary", candidates = 0, evaluated = 0, failed = 0 });
        return 0;
    }
    if (settings is not null)
    {
        tenantId = settings.TenantId;
        clientId = settings.ClientId;
    }

    stage = "createFixture";
    fixture = Directory.CreateTempSubdirectory("LocalMIPScanner-lab-");
    string sample = Path.Combine(fixture.FullName, "synthetic.docx");
    string? hashBefore = null;
    DateTime writeTimeBefore = default;
    if (!silentMode)
    {
        CreateSample(sample);
        hashBefore = HashFile(sample);
        writeTimeBefore = System.IO.File.GetLastWriteTimeUtc(sample);
    }

    stage = "initializeSdk";
    MIP.Initialize(MipComponent.File, Path.Combine(AppContext.BaseDirectory, "x64"));
    var app = new ApplicationInfo
    {
        ApplicationId = selfTest ? "b21d7240-9a24-4913-ab33-212c5b7cf88a" : clientId.ToString(),
        ApplicationName = "LocalMIPScanner Lab",
        ApplicationVersion = "1.0"
    };
    var configuration = new MipConfiguration(app, fixture.FullName,
        Microsoft.InformationProtection.LogLevel.Error, selfTest, CacheStorageType.InMemory)
    {
        DiagnosticOverride = new DiagnosticConfiguration { IsMinimalTelemetryEnabled = true },
        LoggerDelegateOverride = new LabLogger()
    };
    using var context = MIP.CreateMipContext(configuration);
    int failed = 0;
    try
    {
        if (selfTest)
        {
            stage = "selfTest";
            VerifySyntheticCallback();
            VerifyAuditInput(fixture.FullName);
            VerifyOfficeInput(fixture.FullName, sample, context);
            _ = new LabAuth(Guid.NewGuid(), Guid.NewGuid(), null, windowsSilent: true);
            Emit(new
            {
                @event = "selfTest", nativeSdkInitialized = true, syntheticCallbackPassed = true,
                mappedAuditPassed = true, officeInputGuardsPassed = true
            });
        }
        else
        {
            string? user = settings is null ? args[2] : settings.ExpectedUser;
            auth = new LabAuth(tenantId, clientId, user, silentMode);
            stage = "loadProfile";
            consent = new LabConsent(silentMode);
            using var profile = await MIP.LoadFileProfileAsync(
                new FileProfileSettings(context, CacheStorageType.InMemory, consent));
            if (silentMode)
            {
                stage = "resolveWindowsAccount";
                // Let the SDK supply the policy service's actual authority and resource.
                profile.AcquirePolicyAuthToken(Cloud.Commercial, auth);
                user = auth.AuthenticatedUser ?? throw new InvalidOperationException("Could not resolve the Windows account.");
                Emit(new { @event = "authentication", mode = "windowsSilent", outcome = "authenticated" });
            }
            stage = "loadPolicy";
            using var engine = await profile.AddEngineAsync(new FileEngineSettings(
                Guid.NewGuid().ToString(), auth, "LocalMIPScanner lab", "en-US")
            {
                Identity = new Identity(user!),
                LoadSensitivityTypes = true
            });
            Emit(new
            {
                @event = "policy",
                hasClassificationRules = engine.HasClassificationRules,
                publishedLabelCount = engine.SensitivityLabels.Count,
                rulePackageCount = engine.SensitivityTypes.Count
            });

            if (auditLog)
            {
                stage = "classifyAuditFindings";
                foreach (var candidate in candidates)
                {
                    try
                    {
                        using var stream = candidate.OpenVerified();
                        await Classify(engine, stream, candidate.Path, "localAudit", new(candidate.Evidence));
                    }
                    catch (Exception error) when (error is not OutOfMemoryException)
                    {
                        failed++;
                        Emit(new
                        {
                            @event = "auditFileError", path = candidate.Path,
                            reason = error is AuditInputException ? error.Message : error.GetBaseException().GetType().Name,
                            authError = auth.ErrorCode
                        });
                    }
                }
                Emit(new { @event = "auditSummary", candidates = candidates.Count, evaluated = candidates.Count - failed, failed });
            }
            else if (listOfficeLabels)
            {
                stage = "listOfficeLabels";
                foreach (var label in OfficeLabelCopy.LeafLabels(engine.SensitivityLabels).Where(item => item.IsActive))
                    Emit(new { @event = "officeLabel", labelId = label.Id, name = label.Name,
                        addsProtection = OfficeLabelCopy.AddsProtection(label) });
            }
            else if (officeCopy is not null)
            {
                stage = "applyAndVerifyOfficeCopy";
                await officeCopy.ApplyAsync(engine, context);
                Emit(new
                {
                    @event = "officeCopyLabeled", source = officeCopy.Source, output = officeCopy.Output,
                    labelId = officeCopy.LabelId, verified = true, sourceUnchanged = true, protectionApplied = false
                });
            }
            else if (!checkSso)
            {
                stage = "classifyBaseline";
                using var stream = System.IO.File.Open(sample, FileMode.Open, FileAccess.Read, FileShare.Read);
                await Classify(engine, stream, sample, "baseline", new(Guid.Empty));
                if (sitId != Guid.Empty)
                {
                    stage = "classifySimulatedMatch";
                    using var matchedStream = System.IO.File.Open(sample, FileMode.Open, FileAccess.Read, FileShare.Read);
                    await Classify(engine, matchedStream, sample, "simulatedMatch", new(sitId));
                }
            }
        }
    }
    finally
    {
        context.ShutDown();
    }

    if (silentMode) return failed == 0 ? 0 : 1;
    stage = "verifyFixture";
    bool unchanged = hashBefore == HashFile(sample) && writeTimeBefore == System.IO.File.GetLastWriteTimeUtc(sample);
    Emit(new { @event = "integrity", sampleUnchanged = unchanged });
    return unchanged ? 0 : 1;
}
catch (Exception error)
{
    // Keep exception messages, claims, access tokens and UPNs out of the report.
    Emit(new
    {
        @event = "error", stage, type = error.GetBaseException().GetType().Name,
        reason = error is AuditInputException ? error.Message : null,
        authError = auth?.ErrorCode,
        sdkConsentRequired = consent?.DeniedForSilentMode ?? false
    });
    return 1;
}
finally
{
    try { fixture?.Delete(recursive: true); }
    catch (IOException) { Console.Error.WriteLine("A temporary SDK fixture could not be removed."); }
    catch (UnauthorizedAccessException) { Console.Error.WriteLine("A temporary SDK fixture could not be removed."); }
}

static async Task Classify(IFileEngine engine, Stream stream, string path, string scenario, LabExecutionState state)
{
    using var handler = await engine.CreateFileHandlerAsync(stream, path,
        isAuditDiscoveryEnabled: false, fileExecutionState: state, isGetSensitivityLabelAuditDiscoveryEnabled: false);
    var actions = await handler.ClassifyAsync();
    Emit(new
    {
        @event = "classification",
        scenario,
        path = scenario == "localAudit" ? path : null,
        callbackCalls = state.CallbackCalls,
        requested = state.Requests.OrderBy(request => request.ClassificationId).Select(request =>
            new { sitId = request.ClassificationId, rulePackageId = request.RulePackageId }),
        simulatedMatchSupplied = state.SimulatedMatchSupplied,
        suppliedSits = state.SuppliedSits.Order(),
        actions = actions.Select(action => action.ActionType.ToString()).ToArray(),
        recommendedLabelIds = actions.OfType<RecommendLabelAction>().Select(action => action.Label.Id).Distinct().ToArray(),
        requiredLabelIds = actions.OfType<ApplyLabelAction>().Select(action => action.Label.Id).Distinct().ToArray()
    });
}

static void VerifySyntheticCallback()
{
    Guid expected = Guid.Parse("28636834-c509-4f55-a433-a72f7660381d");
    var request = new ClassificationRequest { ClassificationId = expected.ToString(), RulePackageId = "fixture" };
    var other = new ClassificationRequest { ClassificationId = Guid.Empty.ToString(), RulePackageId = "fixture" };
    var baseline = new LabExecutionState(Guid.Empty);
    var simulated = new LabExecutionState(expected);
    var matches = simulated.GetClassificationResults(null!, [request, other]);
    if (baseline.GetClassificationResults(null!, [request]).Count != 0 ||
        matches.Count != 1 || matches[request.ClassificationId].Count != 1 ||
        !simulated.SimulatedMatchSupplied || simulated.CallbackCalls != 1 || simulated.Requests.Count != 2)
        throw new InvalidOperationException("Unexpected synthetic callback result.");
}

static void VerifyAuditInput(string directory)
{
    Guid sit = Guid.Parse("28636834-c509-4f55-a433-a72f7660381d");
    var settings = new AuditSettings(sit, sit, [directory], [new("fixture-rule", sit, 75)]);
    var path = Path.Combine(directory, "fixture.txt");
    var log = Path.Combine(directory, "fixture.jsonl");
    System.IO.File.WriteAllText(path, "synthetic fixture");
    var runId = Guid.NewGuid();
    System.IO.File.WriteAllLines(log, new object[]
    {
        new { @event = "start", runId },
        new { @event = "contentAudit", outcome = "completed", path, sha256 = HashFile(path),
            matchesByRule = new Dictionary<string, int> { ["fixture-rule"] = 2 } },
        new { @event = "summary", runId }
    }.Select(row => JsonSerializer.Serialize(row)));

    var candidate = AuditCandidate.ReadLog(log, settings).Single();
    using (candidate.OpenVerified()) { }
    var state = new LabExecutionState(candidate.Evidence);
    var request = new ClassificationRequest { ClassificationId = sit.ToString(), RulePackageId = "fixture" };
    var supplied = state.GetClassificationResults(null!, [request])[request.ClassificationId];
    if (supplied.Count != 2 || supplied.ConfidenceLevel != 75 || state.SimulatedMatchSupplied)
        throw new InvalidOperationException("Mapped audit evidence was not preserved.");

    System.IO.File.WriteAllText(path, "modified fixture");
    try
    {
        using var stale = candidate.OpenVerified();
        throw new InvalidOperationException("Stale audit evidence was accepted.");
    }
    catch (AuditInputException error) when (error.Message == "file_changed_since_audit") { }
}

static void VerifyOfficeInput(string directory, string word, MipContext context)
{
    var id = Guid.NewGuid();
    var settings = new AuditSettings(id, id, [directory], [new("fixture-rule", id, 85)]);
    using var statusInput = System.IO.File.Open(word, FileMode.Open, FileAccess.Read, FileShare.Read);
    var status = FileHandler.GetFileStatus(statusInput, word, context, null);
    if (status.IsLabeled() || status.IsProtected() || status.ContainsProtectedObjects())
        throw new InvalidOperationException("Synthetic Word fixture should be unlabeled and unprotected.");

    var label = id.ToString();
    string wordOutput = Path.Combine(directory, "word-copy.docx");
    _ = OfficeLabelCopy.Prepare(settings, word, wordOutput, label);
    Reject(() => OfficeLabelCopy.Prepare(settings, word, word, label), "output_must_be_new");
    string existing = Path.Combine(directory, "existing.docx");
    System.IO.File.WriteAllText(existing, "existing fixture");
    Reject(() => OfficeLabelCopy.Prepare(settings, word, existing, label), "output_must_be_new");
    if (System.IO.File.ReadAllText(existing) != "existing fixture")
        throw new InvalidOperationException("Input validation modified an existing output.");
    Reject(() => OfficeLabelCopy.Prepare(settings, word, Path.Combine(directory, "copy.xlsx"), label),
        "output_extension_must_match");
    Reject(() => OfficeLabelCopy.Prepare(settings, word, Path.Combine(directory, "..", "copy.docx"), label),
        "office_path_outside_configured_roots");
    Reject(() => OfficeLabelCopy.Prepare(settings, Path.Combine(directory, "fixture.txt"),
        Path.Combine(directory, "copy.txt"), label), "office_format_required");

    var disguised = Path.Combine(directory, "disguised.docx");
    System.IO.File.WriteAllText(disguised, "plain text");
    Reject(() => OfficeLabelCopy.Prepare(settings, disguised, wordOutput, label), "office_package_required");

    foreach (var (extension, part) in new[] { (".xlsx", "xl/workbook.xml"), (".pptx", "ppt/presentation.xml") })
    {
        var input = Path.Combine(directory, "format-fixture" + extension);
        using (var archive = ZipFile.Open(input, ZipArchiveMode.Create))
            foreach (var entry in new[] { "[Content_Types].xml", "_rels/.rels", part })
                archive.CreateEntry(entry);
        _ = OfficeLabelCopy.Prepare(settings, input, Path.Combine(directory, "copy" + extension), label);
    }
    if (System.IO.File.Exists(wordOutput)) throw new InvalidOperationException("Input validation created a copy.");

    static void Reject(System.Action check, string reason)
    {
        try { check(); }
        catch (AuditInputException error) when (error.Message == reason) { return; }
        throw new InvalidOperationException($"The Office copy guard did not reject {reason}.");
    }
}

static void CreateSample(string path)
{
    using var archive = ZipFile.Open(path, ZipArchiveMode.Create);
    WritePart("[Content_Types].xml", """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
        """);
    WritePart("_rels/.rels", """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """);
    WritePart("word/document.xml", """
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body><w:p><w:r><w:t>LocalMIPScanner synthetic lab fixture</w:t></w:r></w:p></w:body>
        </w:document>
        """);

    void WritePart(string name, string text)
    {
        using var writer = new StreamWriter(archive.CreateEntry(name).Open());
        writer.Write(text);
    }
}

static string HashFile(string path)
{
    using var stream = System.IO.File.OpenRead(path);
    return Convert.ToHexString(SHA256.HashData(stream));
}

static void Emit<T>(T value) => Console.WriteLine(JsonSerializer.Serialize(value));

sealed class LabExecutionState(Dictionary<Guid, SitEvidence> evidence, bool simulated = false) : FileExecutionState
{
    public LabExecutionState(Guid simulatedSit) : this(simulatedSit == Guid.Empty
        ? [] : new() { [simulatedSit] = new(1, 85) }, simulatedSit != Guid.Empty) { }

    private readonly string scenarioId = Guid.NewGuid().ToString();
    public int CallbackCalls { get; private set; }
    public bool SimulatedMatchSupplied => simulated && SuppliedSits.Count > 0;
    public HashSet<Guid> SuppliedSits { get; } = [];
    public HashSet<(string ClassificationId, string RulePackageId)> Requests { get; } = [];

    public override DataState GetDataState() => DataState.Rest;
    public override string GetApplicationScenarioId() => scenarioId;
    public override Dictionary<string, string> GetAuditMetadata() => [];

    public override Dictionary<string, ClassificationResult> GetClassificationResults(
        IFileHandler fileHandler, List<ClassificationRequest> requests)
    {
        CallbackCalls++;
        var results = new Dictionary<string, ClassificationResult>();
        foreach (var request in requests)
        {
            Requests.Add((request.ClassificationId, request.RulePackageId));
            if (!Guid.TryParse(request.ClassificationId, out var id) || !evidence.TryGetValue(id, out var match))
                continue;

            results[request.ClassificationId] = new ClassificationResult
            {
                Id = request.ClassificationId,
                Name = simulated ? "Synthetic lab match" : "Local audit rule match",
                Count = match.Count,
                ConfidenceLevel = match.Confidence,
                SensitiveInformationDetections = "",
                DetailedClassificationAttributes = [new() { ConfidenceLevel = match.Confidence, Count = match.Count }]
            };
            SuppliedSits.Add(id);
        }

        return results;
    }
}

sealed class LabConsent(bool silent) : IConsentDelegate
{
    public bool DeniedForSilentMode { get; private set; }

    public Consent GetUserConsent(string url)
    {
        if (silent)
        {
            DeniedForSilentMode = true;
            return Consent.Reject;
        }
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.Scheme != "https")
            return Consent.Reject;
        Console.Error.Write($"Allow the MIP SDK to connect to {uri.Host}? [y/N] ");
        return string.Equals(Console.ReadLine(), "y", StringComparison.OrdinalIgnoreCase)
            ? Consent.Accept : Consent.Reject;
    }
}

// The lab emits its own structured diagnostics without SDK log messages.
sealed class LabLogger : ILoggerDelegateV3
{
    public void Init(string path) { }
    public void Flush() { }
    public void WriteToLog(LogMessageData message) { }
    public void WriteToLog(Microsoft.InformationProtection.LogLevel level, string message,
        string function, string file, int line) { }
}

sealed class LabAuth(Guid tenantId, Guid clientId, string? expectedUser, bool windowsSilent) : IAuthDelegate
{
    private const string PolicyService = "870c4f2e-85b6-4d43-bdda-6ed9a579b725";
    private readonly IPublicClientApplication client = BuildClient(tenantId, clientId, windowsSilent);
    private readonly object gate = new();
    private IAccount? account;

    public string? ErrorCode { get; private set; }
    public string? AuthenticatedUser => account?.Username;

    private static IPublicClientApplication BuildClient(Guid tenant, Guid app, bool silent)
    {
        var builder = PublicClientApplicationBuilder.Create(app.ToString())
            .WithAuthority($"https://login.microsoftonline.com/{tenant}");
        return (silent
            ? builder.WithBroker(new BrokerOptions(BrokerOptions.OperatingSystems.Windows))
            : builder.WithRedirectUri("http://localhost")).Build();
    }

    public string AcquireToken(Identity identity, string authority, string resource, string claims)
    {
        lock (gate)
        {
            ErrorCode = null;
            if (!Uri.TryCreate(authority, UriKind.Absolute, out var issuer) || issuer.Scheme != "https" ||
                issuer.Host is not ("login.microsoftonline.com" or "login.windows.net") ||
                (resource != PolicyService && (!Uri.TryCreate(resource, UriKind.Absolute, out var audience) ||
                    audience.Scheme != "https" || audience.UserInfo.Length != 0 ||
                    audience.Query.Length != 0 || audience.Fragment.Length != 0)))
            {
                ErrorCode = "unsupported_auth_challenge";
                return "";
            }

            try
            {
                using var deadline = new CancellationTokenSource(TimeSpan.FromMinutes(3));
                var result = AcquireAsync(resource.TrimEnd('/') + "/.default", claims, deadline.Token)
                    .GetAwaiter().GetResult();
                if (!Guid.TryParse(result.TenantId, out var actualTenant) || actualTenant != tenantId ||
                    string.IsNullOrWhiteSpace(result.Account.Username) ||
                    ((account?.Username ?? expectedUser) is { } user &&
                        !string.Equals(result.Account.Username, user, StringComparison.OrdinalIgnoreCase)))
                {
                    ErrorCode = "unexpected_tenant_or_user";
                    return "";
                }

                account = result.Account;
                return result.AccessToken;
            }
            catch (MsalUiRequiredException error) when (windowsSilent) { ErrorCode = "interaction_required:" + error.ErrorCode; }
            catch (MsalException error) { ErrorCode = error.ErrorCode; }
            catch (OperationCanceledException) { ErrorCode = "sign_in_timeout"; }
            catch (Exception error) { ErrorCode = error.GetType().Name; }
            return "";
        }
    }

    private async Task<AuthenticationResult> AcquireAsync(string scope, string claims, CancellationToken cancellationToken)
    {
        string[] scopes = [scope];
        if (windowsSilent)
        {
            var silent = client.AcquireTokenSilent(scopes, account ?? PublicClientApplication.OperatingSystemAccount);
            if (!string.IsNullOrWhiteSpace(claims)) silent = silent.WithClaims(claims);
            return await silent.ExecuteAsync(cancellationToken);
        }
        if (account is not null)
        {
            try
            {
                var silent = client.AcquireTokenSilent(scopes, account);
                if (!string.IsNullOrWhiteSpace(claims)) silent = silent.WithClaims(claims);
                return await silent.ExecuteAsync(cancellationToken);
            }
            catch (MsalUiRequiredException)
            {
                // The service may require another interactive sign-in for this resource.
            }
        }

        var interactive = client.AcquireTokenInteractive(scopes).WithLoginHint(expectedUser);
        if (!string.IsNullOrWhiteSpace(claims)) interactive = interactive.WithClaims(claims);
        return await interactive.ExecuteAsync(cancellationToken);
    }
}
