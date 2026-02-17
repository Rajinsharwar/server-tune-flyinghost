<?php
http_response_code(403);

@session_start();

// Unset all session variables
$_SESSION = array();

// If a session cookie is used, delete the cookie
if (ini_get("session.use_cookies")) {
    $params = session_get_cookie_params();
    setcookie(session_name(), '', time() - 42000,
        $params["path"], $params["domain"],
        $params["secure"], $params["httponly"]
    );
}

// Finally, destroy the session
session_destroy();

?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Logged Out!</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
        * {
            box-sizing: border-box;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Oxygen;
        }

        body {
            margin: 0;
            height: 100vh;
            background: linear-gradient(135deg, #0f172a, #020617);
            display: flex;
            align-items: center;
            justify-content: center;
            color: #e5e7eb;
        }

        .card {
            background: rgba(15, 23, 42, 0.9);
            border-radius: 16px;
            padding: 40px;
            max-width: 520px;
            text-align: center;
            box-shadow: 0 20px 40px rgba(0, 0, 0, 0.6);
        }

        .icon {
            font-size: 52px;
            margin-bottom: 16px;
        }

        h1 {
            font-size: 24px;
            margin-bottom: 12px;
        }

        p {
            font-size: 16px;
            color: #cbd5f5;
            line-height: 1.6;
        }

        .highlight {
            color: #38bdf8;
            font-weight: 600;
        }

        .footer {
            margin-top: 28px;
            font-size: 13px;
            color: #94a3b8;
        }
    </style>
</head>
<body>
    <div class="card">
        <div class="icon">🔒</div>

        <h1>Logged Out from PHPMyAdmin</h1>

        <p>
            Please close this tab and open
            <span class="highlight">phpMyAdmin</span>
            from your
            <span class="highlight">FlyingHost Dashboard</span>.
        </p>

        <p>
            For security reasons, direct access to phpMyAdmin is not allowed.
        </p>

        <div class="footer">
            FlyingHost • Secure Database Access
        </div>
    </div>
</body>
</html>
