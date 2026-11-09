<?php
/**
 * A request carrying a Donor Token must not be cached, indexed or leaked to
 * other sites through the Referer header. The parameter being present is what
 * counts: unknown tokens get the same treatment as valid ones.
 */

namespace Schrauger\DonorThankYou;

\defined('ABSPATH') || exit;

function is_token_request(): bool {
    return isset($_GET['donorid']);
}

\add_action('send_headers', __NAMESPACE__ . '\\protect_token_request');
function protect_token_request() {
    if (!is_token_request()) {
        return;
    }

    \nocache_headers();
    \defined('DONOTCACHEPAGE') || \define('DONOTCACHEPAGE', true);
    \header('Referrer-Policy: same-origin');
    // Sent as well as the meta tag, which a theme change could drop.
    \header('X-Robots-Tag: noindex, nofollow, noarchive');
}

\add_filter('wp_robots', __NAMESPACE__ . '\\noindex_token_request');
function noindex_token_request(array $robots): array {
    if (is_token_request()) {
        $robots['noindex']   = true;
        $robots['nofollow']  = true;
        $robots['noarchive'] = true;
    }

    return $robots;
}
