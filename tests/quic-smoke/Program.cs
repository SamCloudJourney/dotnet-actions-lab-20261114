using System.Net;
using System.Net.Quic;
using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

if (!QuicListener.IsSupported)
{
    Console.WriteLine("QUIC_UNSUPPORTED");
    return 2;
}

using var key = RSA.Create(2048);
var request = new CertificateRequest("CN=localhost", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, true));
request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(new OidCollection { new Oid("1.3.6.1.5.5.7.3.1") }, true));
var san = new SubjectAlternativeNameBuilder();
san.AddDnsName("localhost");
request.CertificateExtensions.Add(san.Build());
using var certificate = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-1), DateTimeOffset.UtcNow.AddMinutes(10));
var protocol = new SslApplicationProtocol("quic-smoke");
var options = new QuicListenerOptions
{
    ListenEndPoint = new IPEndPoint(IPAddress.Loopback, 0),
    ApplicationProtocols = [protocol],
    ConnectionOptionsCallback = (_, _, _) => ValueTask.FromResult(new QuicServerConnectionOptions
    {
        DefaultCloseErrorCode = 1,
        DefaultStreamErrorCode = 1,
        ServerAuthenticationOptions = new SslServerAuthenticationOptions
        {
            ApplicationProtocols = [protocol],
            ServerCertificate = certificate
        }
    })
};
await using var listener = await QuicListener.ListenAsync(options);
Console.WriteLine($"QUIC_LISTENER_READY runtime={Environment.Version} arch={System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture} port={((IPEndPoint)listener.LocalEndPoint).Port}");
return 0;
