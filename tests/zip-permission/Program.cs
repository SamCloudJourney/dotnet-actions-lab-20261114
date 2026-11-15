// Public regression experiment for dotnet/runtime#137413 (already disclosed).
// Compares Unix mode of the first and repeated extraction of the same ZIP entry.
// No private vulnerability claims, exploit payloads, secrets or external targets.
using System.IO.Compression;

if (OperatingSystem.IsWindows())
{
    Console.WriteLine("SKIPPED_WINDOWS");
    return;
}
string root = Path.Combine(Path.GetTempPath(), "public-dotnet-zip-" + Guid.NewGuid().ToString("N"));
string sourceDirectory = Path.Combine(root, "source");
string destinationDirectory = Path.Combine(root, "destination");
string archivePath = Path.Combine(root, "sample.zip");
try
{
    Directory.CreateDirectory(sourceDirectory);
    Directory.CreateDirectory(destinationDirectory);
    string input = Path.Combine(sourceDirectory, "sample.sh");
    File.WriteAllText(input, "#!/bin/sh\necho public-regression-only\n");
    var expected = UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute |
        UnixFileMode.GroupRead | UnixFileMode.GroupExecute |
        UnixFileMode.OtherRead | UnixFileMode.OtherExecute;
    File.SetUnixFileMode(input, expected);
    ZipFile.CreateFromDirectory(sourceDirectory, archivePath);
    ZipFile.ExtractToDirectory(archivePath, destinationDirectory);
    string output = Path.Combine(destinationDirectory, "sample.sh");
    int freshMode = (int)File.GetUnixFileMode(output);
    ZipFile.ExtractToDirectory(archivePath, destinationDirectory, overwriteFiles: true);
    int overwrittenMode = (int)File.GetUnixFileMode(output);
    Console.WriteLine($"FRESH_OCTAL={Convert.ToString(freshMode, 8)}");
    Console.WriteLine($"OVERWRITE_OCTAL={Convert.ToString(overwrittenMode, 8)}");
    Console.WriteLine(freshMode == overwrittenMode ? "PERMISSION_REGRESSION_NOT_OBSERVED" : "KNOWN_PERMISSION_REGRESSION_OBSERVED");
}
finally
{
    if (Directory.Exists(root))
    {
        Directory.Delete(root, recursive: true);
    }
}
