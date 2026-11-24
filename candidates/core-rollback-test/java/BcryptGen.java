import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;

/** Prints a BCrypt hash (cost 10) for the password given as the first argument. Test helper only. */
public final class BcryptGen {
    public static void main(String[] args) {
        System.out.println(new BCryptPasswordEncoder().encode(args[0]));
    }
}
