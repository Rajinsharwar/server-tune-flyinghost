<?php
declare(strict_types=1);

/**
 * Single signon for phpMyAdmin
 *
 * This is just example how to use session based single signon with
 * phpMyAdmin, it is not intended to be perfect code and look, only
 * shows how you can integrate this functionality in your application.
 */

function get_wp_config( $config ) {
    return trim( shell_exec("wp config get $config --type=constant --path=/var/www/public --skip-plugins --skip-themes --skip-packages --quiet") ?? '' );
}

function fail_phpmyadmin_login() {
    header('Expires: Wed, 11 Jan 1984 05:00:00 GMT');
    header('Last-Modified: ' . gmdate('D, d M Y H:i:s') . ' GMT');
    header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
    header('Pragma: no-cache');
    header("HTTP/1.1 403 Forbidden");
    die( 'Invalid Login. Please try again' );
}

if ( 'POST' !== strtoupper( $_SERVER['REQUEST_METHOD'] ?? '' ) ) {
    fail_phpmyadmin_login();
}

$flyinghost_site_token = get_wp_config( "FLYINGHOST_SITE_TOKEN" );

if ( '' === $flyinghost_site_token ) {
    fail_phpmyadmin_login();
}

$email      = isset( $_POST['email'] ) ? filter_var( stripslashes( $_POST['email'] ), FILTER_SANITIZE_EMAIL ) : '';
$expires_at = isset( $_POST['expires_at'] ) ? abs( (int) $_POST['expires_at'] ) : 0;
$sig = isset( $_POST['sig'] ) ? htmlspecialchars( trim( stripslashes( $_POST['sig'] ) ), ENT_QUOTES, 'UTF-8' ) : '';
$ttl        = 900;

$now        = time();

if ( '' === $email || ! filter_var( $email, FILTER_VALIDATE_EMAIL ) || ! $expires_at || '' === $sig ) {
    fail_phpmyadmin_login();
}

if ( $expires_at < $now || ( $expires_at - $now ) > $ttl ) {
    fail_phpmyadmin_login();
}

$expected = hash_hmac( 'sha256', $email . '|' . $expires_at, $flyinghost_site_token );
if ( ! hash_equals( $expected, $sig ) ) {
    fail_phpmyadmin_login();
}

$db_name = get_wp_config( 'DB_NAME' );
$db_user = get_wp_config( 'DB_USER' );
$db_pass = get_wp_config( 'DB_PASSWORD' );
$db_host = get_wp_config( 'DB_HOST' );
$db_port = 3306;

/* Use cookies for session */
ini_set('session.use_cookies', 'true');
$secure_cookie = false;
session_set_cookie_params(0, '/', '', $secure_cookie, true);
$session_name = 'SignonSessionFlyingHostPhpMyAdmin';
session_name($session_name);
@session_start();

/* Store there credentials */
$_SESSION['PMA_single_signon_user'] = $db_user;
$_SESSION['PMA_single_signon_password'] = $db_pass;
$_SESSION['PMA_single_signon_host'] = $db_host;
$_SESSION['PMA_single_signon_port'] = $db_port;
$_SESSION['PMA_single_signon_cfgupdate'] = ['verbose' => 'FlyingHost PHPMyAdmin Login'];
$_SESSION['PMA_single_signon_token'] = md5(uniqid(bin2hex(random_bytes(rand(3, 4))), true));
$id = session_id();

@session_write_close();

header('Location: index.php');
exit;
