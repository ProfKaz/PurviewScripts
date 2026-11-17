using System.IO.Compression;
using System.Security.Cryptography;
using Microsoft.InformationProtection;
using Microsoft.InformationProtection.File;

sealed record OfficeLabelCopy(string Source, string Output, Guid LabelId)
{
    private const int MaxPilotBytes = 32 * 1024 * 1024;

    public static OfficeLabelCopy Prepare(AuditSettings settings, string sourcePath, string outputPath, string label)
    {
        var source = AuditCandidate.NormalizePath(sourcePath);
        var output = AuditCandidate.NormalizePath(outputPath);
        var extension = Path.GetExtension(source).ToLowerInvariant();
        if (extension is not (".docx" or ".xlsx" or ".pptx"))
            throw new AuditInputException("office_format_required");
        if (!string.Equals(extension, Path.GetExtension(output), StringComparison.OrdinalIgnoreCase))
            throw new AuditInputException("output_extension_must_match");
        if (!settings.ContainsPath(source) || !settings.ContainsPath(output))
            throw new AuditInputException("office_path_outside_configured_roots");
        if (string.Equals(source, output, StringComparison.OrdinalIgnoreCase) || File.Exists(output) || Directory.Exists(output))
            throw new AuditInputException("output_must_be_new");
        if (!Guid.TryParse(label, out var labelId) || labelId == Guid.Empty)
            throw new AuditInputException("invalid_office_label_id");

        AuditCandidate.AssertLocalPath(source);
        AuditCandidate.AssertLocalPath(Path.GetDirectoryName(output)!);
        using var stream = File.Open(source, FileMode.Open, FileAccess.Read, FileShare.Read);
        AssertOfficePackage(stream, extension);
        return new(source, output, labelId);
    }

    public static IEnumerable<Label> LeafLabels(IEnumerable<Label> labels)
    {
        foreach (var label in labels)
        {
            if (label.Children.Count == 0)
                yield return label;
            else
                foreach (var child in LeafLabels(label.Children))
                    yield return child;
        }
    }

    public static bool AddsProtection(Label label) =>
        label.HasRightsManagementPolicy || label.HasDoNotForwardProtection ||
        label.HasEncryptOnlyProtection || label.HasAdhocProtection || !string.IsNullOrEmpty(label.DoubleKeyUrl);

    public async Task ApplyAsync(IFileEngine engine, MipContext context, bool reportActivity = false)
    {
        var label = LeafLabels(engine.SensitivityLabels).FirstOrDefault(item =>
            Guid.TryParse(item.Id, out var id) && id == LabelId);
        if (label is null || !label.IsActive)
            throw new AuditInputException("label_not_published_as_active_leaf");
        if (AddsProtection(label))
            throw new AuditInputException("protected_label_not_allowed_in_office_pilot");

        AuditCandidate.AssertLocalPath(Source);
        var directory = Path.GetDirectoryName(Output)!;
        AuditCandidate.AssertLocalPath(directory);
        var extension = Path.GetExtension(Source);
        using var sourceLock = File.Open(Source, FileMode.Open, FileAccess.Read, FileShare.Read);
        AuditCandidate.AssertLocalPath(Source);
        AssertOfficePackage(sourceLock, extension);
        var before = SHA256.HashData(sourceLock);
        var modified = File.GetLastWriteTimeUtc(sourceLock.SafeFileHandle);
        using (var statusInput = File.Open(Source, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            var status = FileHandler.GetFileStatus(statusInput, Source, context, null);
            if (status.IsLabeled() || status.IsProtected() || status.ContainsProtectedObjects())
                throw new AuditInputException("source_must_be_unlabeled_and_unprotected");
        }

        var temporary = Path.Combine(directory, $".mip-office-{Guid.NewGuid():N}{extension}");
        bool ownsTemporary = false;
        try
        {
            using var input = File.Open(Source, FileMode.Open, FileAccess.Read, FileShare.Read);
            using var handler = await OpenHandler(engine, input, Source);
            handler.SetLabel(label, new LabelingOptions { AssignmentMethod = AssignmentMethod.Standard },
                new ProtectionSettings());
            if (!string.Equals(Path.GetExtension(handler.OutputFileName), extension, StringComparison.OrdinalIgnoreCase))
                throw new AuditInputException("sdk_requested_extension_change");

            using (var staged = File.Open(temporary, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None))
            {
                ownsTemporary = true;
                if (!await handler.CommitAsync(staged))
                    throw new AuditInputException("office_label_commit_failed");
                staged.Flush(flushToDisk: true);
            }

            using (var verification = File.Open(temporary, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                AssertOfficePackage(verification, extension);
                var status = FileHandler.GetFileStatus(temporary, context, null);
                if (!status.IsLabeled() || status.IsProtected() || status.ContainsProtectedObjects())
                    throw new AuditInputException("office_copy_status_verification_failed");
                using var reopened = await OpenHandler(engine, verification, temporary);
                var applied = reopened.Label;
                if (applied is null || applied.IsProtectionAppliedFromLabel ||
                    !Guid.TryParse(applied.Label.Id, out var appliedId) || appliedId != LabelId)
                    throw new AuditInputException("office_copy_label_verification_failed");
            }

            sourceLock.Position = 0;
            if (!before.AsSpan().SequenceEqual(SHA256.HashData(sourceLock)) ||
                modified != File.GetLastWriteTimeUtc(sourceLock.SafeFileHandle))
                throw new AuditInputException("source_integrity_verification_failed");

            AuditCandidate.AssertLocalPath(directory);
            File.Move(temporary, Output);
            ownsTemporary = false;
            if (reportActivity)
                handler.NotifyCommitSuccessful(Output);
        }
        finally
        {
            if (ownsTemporary) File.Delete(temporary);
        }
    }

    public async Task<string?> ReadLabelForDiscoveryAsync(IFileEngine engine)
    {
        AuditCandidate.AssertLocalPath(Output);
        using var stream = File.Open(Output, FileMode.Open, FileAccess.Read, FileShare.Read);
        using var handler = await engine.CreateFileHandlerAsync(stream, Output, isAuditDiscoveryEnabled: true,
            isGetSensitivityLabelAuditDiscoveryEnabled: true);
        return handler.Label?.Label.Id;
    }

    private static Task<IFileHandler> OpenHandler(IFileEngine engine, Stream stream, string path) =>
        engine.CreateFileHandlerAsync(stream, path, isAuditDiscoveryEnabled: false,
            isGetSensitivityLabelAuditDiscoveryEnabled: false);

    private static void AssertOfficePackage(Stream stream, string extension)
    {
        if (stream.Length > MaxPilotBytes)
            throw new AuditInputException("office_pilot_size_limit");
        var part = extension.ToLowerInvariant() switch
        {
            ".docx" => "word/document.xml",
            ".xlsx" => "xl/workbook.xml",
            ".pptx" => "ppt/presentation.xml",
            _ => throw new AuditInputException("office_format_required")
        };

        try
        {
            using var archive = new ZipArchive(stream, ZipArchiveMode.Read, leaveOpen: true);
            if (archive.GetEntry("[Content_Types].xml") is null || archive.GetEntry("_rels/.rels") is null ||
                archive.GetEntry(part) is null)
                throw new AuditInputException("office_package_required");
        }
        catch (InvalidDataException)
        {
            throw new AuditInputException("office_package_required");
        }
        stream.Position = 0;
    }
}
