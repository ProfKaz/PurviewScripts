using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

sealed record SitEvidence(int Count, int Confidence);

sealed record RuleMapping(string RuleId, Guid SitId, int Confidence);
sealed record AuditSettings(Guid TenantId, Guid ClientId, string[] Roots, RuleMapping[] Rules,
    string? ExpectedUser = null, int MaxFiles = 50)
{
    public bool ContainsPath(string path) => Roots.Any(root => path.StartsWith(
        root.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase));

    public static AuditSettings Read(string path)
    {
        var options = new JsonSerializerOptions(JsonSerializerDefaults.Web)
        {
            UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
            AllowDuplicateProperties = false
        };
        using var input = File.OpenRead(path);
        if (input.Length > 64 * 1024) throw new AuditInputException("configuration_too_large");
        var settings = JsonSerializer.Deserialize<AuditSettings>(input, options);
        if (settings is null || settings.TenantId == Guid.Empty || settings.ClientId == Guid.Empty ||
            settings.Roots is not { Length: >= 1 and <= 32 } ||
            settings.Rules is not { Length: >= 1 and <= 32 } ||
            settings.MaxFiles is < 1 or > 250 ||
            (settings.ExpectedUser is { } user && (!user.Contains('@') || user.Any(char.IsWhiteSpace))))
            throw new AuditInputException("invalid_configuration");

        foreach (var rule in settings.Rules)
            if (rule is null || rule.RuleId is null || !Regex.IsMatch(rule.RuleId, @"^[a-z][a-z0-9-]{0,63}$") ||
                rule.SitId == Guid.Empty || rule.Confidence is < 1 or > 100)
                throw new AuditInputException("invalid_rule_mapping");
        if (settings.Rules.Select(rule => rule.RuleId).Distinct(StringComparer.OrdinalIgnoreCase).Count() != settings.Rules.Length ||
            settings.Rules.Select(rule => rule.SitId).Distinct().Count() != settings.Rules.Length)
            throw new AuditInputException("duplicate_rule_or_sit");

        return settings with { Roots = settings.Roots.Select(AuditCandidate.NormalizePath).ToArray() };
    }
}

sealed record AuditCandidate(string Path, string Sha256, Dictionary<Guid, SitEvidence> Evidence)
{
    private const long MaxFileBytes = 4 * 1024 * 1024;

    public static List<AuditCandidate> ReadLog(string path, AuditSettings settings)
    {
        using var stream = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (stream.Length > 64 * 1024 * 1024) throw new AuditInputException("audit_log_too_large");
        using var reader = new StreamReader(stream, new System.Text.UTF8Encoding(false, true));
        var mapping = settings.Rules.ToDictionary(rule => rule.RuleId, StringComparer.OrdinalIgnoreCase);
        var candidates = new Dictionary<string, AuditCandidate>(StringComparer.OrdinalIgnoreCase);
        string? runId = null;
        bool sealedLog = false;
        while (reader.ReadLine() is { } line)
        {
            if (sealedLog) throw new AuditInputException("records_after_summary");
            using var document = JsonDocument.Parse(line);
            var row = document.RootElement;
            var kind = row.GetProperty("event").GetString();
            if (runId is null)
            {
                if (kind != "start" || !Guid.TryParse(row.GetProperty("runId").GetString(), out _))
                    throw new AuditInputException("invalid_audit_log_header");
                runId = row.GetProperty("runId").GetString();
                continue;
            }
            if (kind == "summary")
            {
                if (runId != row.GetProperty("runId").GetString()) throw new AuditInputException("wrong_audit_run");
                sealedLog = true;
                continue;
            }
            if (kind != "contentAudit" || row.GetProperty("outcome").GetString() != "completed") continue;

            var evidence = new Dictionary<Guid, SitEvidence>();
            foreach (var match in row.GetProperty("matchesByRule").EnumerateObject())
            {
                if (!mapping.TryGetValue(match.Name, out var rule)) continue;
                if (!match.Value.TryGetInt32(out int count) || count is < 1 or > 1000 ||
                    !evidence.TryAdd(rule.SitId, new(count, rule.Confidence)))
                    throw new AuditInputException("invalid_match_count");
            }
            if (evidence.Count == 0) continue;
            var file = NormalizePath(row.GetProperty("path").GetString());
            if (!settings.ContainsPath(file) ||
                System.IO.Path.GetExtension(file).ToLowerInvariant() is not (".txt" or ".csv"))
                continue;
            if (!row.TryGetProperty("sha256", out var hash) || hash.GetString() is not { Length: 64 } digest ||
                !digest.All(Uri.IsHexDigit))
                throw new AuditInputException("audit_log_requires_content_hash");

            if (!candidates.TryAdd(file, new(file, digest, evidence)))
                throw new AuditInputException("duplicate_audit_candidate");
            if (candidates.Count > settings.MaxFiles) throw new AuditInputException("too_many_audit_candidates");
        }

        if (!sealedLog) throw new AuditInputException("audit_log_missing_summary");
        return [.. candidates.Values];
    }

    public FileStream OpenVerified()
    {
        AssertLocalPath(Path);
        var stream = File.Open(Path, FileMode.Open, FileAccess.Read, FileShare.Read);
        try
        {
            AssertLocalPath(Path);
            if (stream.Length > MaxFileBytes || !string.Equals(Convert.ToHexString(SHA256.HashData(stream)),
                Sha256, StringComparison.OrdinalIgnoreCase))
                throw new AuditInputException("file_changed_since_audit");
            stream.Position = 0;
            return stream;
        }
        catch
        {
            stream.Dispose();
            throw;
        }
    }

    public static void AssertLocalPath(string path)
    {
        var root = System.IO.Path.GetPathRoot(path)!;
        if (new DriveInfo(root).DriveType is not (DriveType.Fixed or DriveType.Removable or DriveType.Ram))
            throw new AuditInputException("file_not_on_local_drive");
        for (string? current = path; current is not null; current = System.IO.Path.GetDirectoryName(current))
            if ((File.GetAttributes(current) & (FileAttributes.ReparsePoint | FileAttributes.Offline)) != 0)
                throw new AuditInputException("file_or_ancestor_unavailable");
    }

    public static string NormalizePath(string? path)
    {
        if (path is null || !Regex.IsMatch(path, @"^[a-zA-Z]:\\") || path.IndexOf(':', 2) >= 0)
            throw new AuditInputException("expected_local_absolute_path");
        return System.IO.Path.GetFullPath(path);
    }
}

sealed class AuditInputException(string code) : IOException(code);
