using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.Identity.Client;
using Microsoft.InformationProtection;
using Microsoft.InformationProtection.File;
using Microsoft.InformationProtection.Policy;

if (args is ["--help"] or [])
{
    Console.WriteLine("MipSdkAudit <tenant-guid> <client-guid> <test-user-upn> [sit-guid]");
    Console.WriteLine("MipSdkAudit --self-test");
    return 0;
}

bool selfTest = args is ["--self-test"];
Guid tenantId = default, clientId = default, sitId = default;
if (!selfTest && (args.Length is < 3 or > 4 ||
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

var stage = "createFixture";
DirectoryInfo? fixture = null;
LabAuth? auth = null;
try
{
    fixture = Directory.CreateTempSubdirectory("LocalMIPScanner-lab-");
    string sample = Path.Combine(fixture.FullName, "synthetic.docx");
    CreateSample(sample);
    string hashBefore = HashFile(sample);
    DateTime writeTimeBefore = System.IO.File.GetLastWriteTimeUtc(sample);

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
    try
    {
        if (selfTest)
        {
            stage = "selfTest";
            VerifySyntheticCallback();
            Emit(new { @event = "selfTest", nativeSdkInitialized = true, syntheticCallbackPassed = true });
        }
        else
        {
            string user = args[2];
            auth = new LabAuth(tenantId, clientId, user);
            stage = "loadProfile";
            using var profile = await MIP.LoadFileProfileAsync(
                new FileProfileSettings(context, CacheStorageType.InMemory, new LabConsent()));
            stage = "loadPolicy";
            using var engine = await profile.AddEngineAsync(new FileEngineSettings(
                Guid.NewGuid().ToString(), auth, "LocalMIPScanner lab", "en-US")
            {
                Identity = new Identity(user),
                LoadSensitivityTypes = true
            });
            Emit(new
            {
                @event = "policy",
                hasClassificationRules = engine.HasClassificationRules,
                publishedLabelCount = engine.SensitivityLabels.Count,
                rulePackageCount = engine.SensitivityTypes.Count
            });

            stage = "classifyBaseline";
            await Classify(engine, sample, "baseline", Guid.Empty);
            if (sitId != Guid.Empty)
            {
                stage = "classifySimulatedMatch";
                await Classify(engine, sample, "simulatedMatch", sitId);
            }
        }
    }
    finally
    {
        context.ShutDown();
    }

    stage = "verifyFixture";
    bool unchanged = hashBefore == HashFile(sample) && writeTimeBefore == System.IO.File.GetLastWriteTimeUtc(sample);
    Emit(new { @event = "integrity", sampleUnchanged = unchanged });
    return unchanged ? 0 : 1;
}
catch (Exception error)
{
    // Keep exception messages, claims, access tokens and UPNs out of the report.
    Emit(new { @event = "error", stage, type = error.GetBaseException().GetType().Name, authError = auth?.ErrorCode });
    return 1;
}
finally
{
    try { fixture?.Delete(recursive: true); }
    catch (IOException) { Console.Error.WriteLine("A temporary SDK fixture could not be removed."); }
    catch (UnauthorizedAccessException) { Console.Error.WriteLine("A temporary SDK fixture could not be removed."); }
}

static async Task Classify(IFileEngine engine, string path, string scenario, Guid simulatedSit)
{
    var state = new LabExecutionState(simulatedSit);
    using var stream = System.IO.File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read);
    using var handler = await engine.CreateFileHandlerAsync(stream, path,
        isAuditDiscoveryEnabled: false, fileExecutionState: state, isGetSensitivityLabelAuditDiscoveryEnabled: false);
    var actions = await handler.ClassifyAsync();
    Emit(new
    {
        @event = "classification",
        scenario,
        callbackCalls = state.CallbackCalls,
        requested = state.Requests.OrderBy(request => request.ClassificationId).Select(request =>
            new { sitId = request.ClassificationId, rulePackageId = request.RulePackageId }),
        simulatedMatchSupplied = state.SimulatedMatchSupplied,
        actions = actions.Select(action => action.ActionType.ToString()).ToArray()
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

sealed class LabExecutionState(Guid simulatedSit) : FileExecutionState
{
    private readonly string scenarioId = Guid.NewGuid().ToString();
    public int CallbackCalls { get; private set; }
    public bool SimulatedMatchSupplied { get; private set; }
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
            if (simulatedSit == Guid.Empty || !Guid.TryParse(request.ClassificationId, out var id) || id != simulatedSit)
                continue;

            results[request.ClassificationId] = new ClassificationResult
            {
                Id = request.ClassificationId,
                Name = "Synthetic lab match",
                Count = 1,
                ConfidenceLevel = 85,
                SensitiveInformationDetections = "",
                DetailedClassificationAttributes = [new() { ConfidenceLevel = 85, Count = 1 }]
            };
            SimulatedMatchSupplied = true;
        }

        return results;
    }
}

sealed class LabConsent : IConsentDelegate
{
    public Consent GetUserConsent(string url)
    {
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

sealed class LabAuth(Guid tenantId, Guid clientId, string user) : IAuthDelegate
{
    private readonly IPublicClientApplication client = PublicClientApplicationBuilder.Create(clientId.ToString())
        .WithAuthority($"https://login.microsoftonline.com/{tenantId}")
        .WithRedirectUri("http://localhost")
        .Build();
    private readonly object gate = new();
    private IAccount? account;

    public string? ErrorCode { get; private set; }

    public string AcquireToken(Identity identity, string authority, string resource, string claims)
    {
        lock (gate)
        {
            ErrorCode = null;
            if (!Uri.TryCreate(authority, UriKind.Absolute, out var issuer) || issuer.Scheme != "https" ||
                issuer.Host is not ("login.microsoftonline.com" or "login.windows.net") ||
                !Uri.TryCreate(resource, UriKind.Absolute, out var audience) || audience.Scheme != "https" ||
                audience.UserInfo.Length != 0 || audience.Query.Length != 0 || audience.Fragment.Length != 0)
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
                    !string.Equals(result.Account.Username, user, StringComparison.OrdinalIgnoreCase))
                {
                    ErrorCode = "unexpected_tenant_or_user";
                    return "";
                }

                account = result.Account;
                return result.AccessToken;
            }
            catch (MsalException error) { ErrorCode = error.ErrorCode; }
            catch (OperationCanceledException) { ErrorCode = "sign_in_timeout"; }
            catch (Exception error) { ErrorCode = error.GetType().Name; }
            return "";
        }
    }

    private async Task<AuthenticationResult> AcquireAsync(string scope, string claims, CancellationToken cancellationToken)
    {
        string[] scopes = [scope];
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

        var interactive = client.AcquireTokenInteractive(scopes).WithLoginHint(user);
        if (!string.IsNullOrWhiteSpace(claims)) interactive = interactive.WithClaims(claims);
        return await interactive.ExecuteAsync(cancellationToken);
    }
}
