import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
public class EnrollmentProbe {
  public static void main(String[] args) throws Exception {
    var client = HttpClient.newHttpClient();
    var req = HttpRequest.newBuilder(URI.create(args[0]))
      .header("Content-Type", "application/json")
      .header("Authorization", "Bearer " + System.getenv("FIXTURE_ENROLL"))
      .PUT(HttpRequest.BodyPublishers.ofString("{\"userId\":\"fixture-user\",\"email\":\"fixture@example.invalid\",\"name\":\"Fixture\"}"))
      .build();
    var res = client.send(req, HttpResponse.BodyHandlers.discarding());
    System.out.println("HTTP " + res.statusCode());
  }
}
