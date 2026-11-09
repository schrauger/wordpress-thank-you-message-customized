<?php
/**
 * Keeps Certificates out of every anonymous listing, while their exact URLs
 * keep working: donors open them without logging in.
 */

namespace Schrauger\DonorThankYou;

\defined('ABSPATH') || exit;

/**
 * Runs $callback while holding a named MySQL lock. add_option() cannot act as
 * a lock because it uses ON DUPLICATE KEY UPDATE.
 *
 * @return mixed The callback's result, or a 503 WP_Error if the lock is busy.
 */
function with_lock(string $name, int $timeout, callable $callback) {
    global $wpdb;

    $lock = 'donor_' . \md5($wpdb->prefix . $name);
    if ('1' !== (string) $wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s, %d)', $lock, $timeout))) {
        return new \WP_Error('donor_busy', 'Another request is in progress. Retry shortly.', ['status' => 503]);
    }

    try {
        return $callback();
    } finally {
        $wpdb->query($wpdb->prepare('SELECT RELEASE_LOCK(%s)', $lock));
    }
}

/**
 * Finds links to PDFs in a message body.
 *
 * @return array<int, array{html: string, href: string}>
 */
function find_pdf_links(string $body): array {
    \preg_match_all('~<a\b[^>]*?\bhref\s*=\s*(["\'])([^"\']+?\.pdf(?:[?#][^"\']*)?)\1[^>]*>.*?</a>~is', $body, $matches, \PREG_SET_ORDER);

    return \array_map(static fn($match) => ['html' => $match[0], 'href' => $match[2]], $matches);
}

/**
 * Marks an attachment as a Certificate. Updates the row directly so that the
 * modified date stays put and no save hooks run.
 */
function protect_attachment(int $attachment_id): void {
    global $wpdb;

    $wpdb->update($wpdb->posts, ['post_status' => 'private'], ['ID' => $attachment_id, 'post_status' => 'inherit']);
    \clean_post_cache($attachment_id);
    \update_post_meta($attachment_id, META_CERTIFICATE, '1');
}

function can_manage_certificates(): bool {
    return \current_user_can('edit_others_posts');
}

// Zip updates skip activation hooks, so upgrades are detected on every load.
\add_action('init', __NAMESPACE__ . '\\maybe_upgrade', 20);
function maybe_upgrade() {
    if (\get_option(OPTION_SCHEMA_VERSION) === SCHEMA_VERSION) {
        return;
    }

    with_lock('upgrade', 0, static function () {
        \add_role(SERVICE_ROLE, 'Donor API Service', [API_CAPABILITY => true]);
        $report = backfill_certificates();
        \update_option(OPTION_BACKFILL_REPORT, $report, false);
        \update_option(OPTION_SCHEMA_VERSION, SCHEMA_VERSION, true);

        if ($report['unresolved'] > 0) {
            \error_log(\sprintf('Donor Thank You: %d certificate link(s) matched no attachment and remain unprotected.', $report['unresolved']));
        }
    });
}

/**
 * Protects every Certificate linked from a Donor Message. Changes attachment
 * status and meta only; filenames, GUIDs, URLs and post bodies stay untouched.
 *
 * @return array{messages: int, links: int, unresolved: int}
 */
function backfill_certificates(): array {
    $report   = ['messages' => 0, 'links' => 0, 'unresolved' => 0];
    $messages = \get_posts([
        'post_type'        => CPT_SLUG,
        'post_status'      => \array_keys(\get_post_stati()),
        'numberposts'      => -1,
        'suppress_filters' => true,
    ]);

    foreach ($messages as $message) {
        $report['messages']++;
        $links = find_pdf_links($message->post_content);

        foreach ($links as $link) {
            $report['links']++;
            $attachment_id = \attachment_url_to_postid($link['href']);

            if (!$attachment_id) {
                $report['unresolved']++;
                continue;
            }

            protect_attachment($attachment_id);

            if (1 === \count($links) && !\get_post_meta($message->ID, META_PDF_ATTACHMENT, true)) {
                \update_post_meta($message->ID, META_PDF_ATTACHMENT, $attachment_id);
            }
        }
    }

    return $report;
}

// Second layer: keeps Certificates out of the query itself, and so out of X-WP-Total.
\add_filter('rest_attachment_query', __NAMESPACE__ . '\\exclude_certificates_from_rest');
function exclude_certificates_from_rest(array $args): array {
    if (!can_manage_certificates()) {
        $args['meta_query']   = $args['meta_query'] ?? [];
        $args['meta_query'][] = ['key' => META_CERTIFICATE, 'compare' => 'NOT EXISTS'];
    }

    return $args;
}

// Runs before redirect_canonical, which would otherwise answer first.
\add_action('template_redirect', __NAMESPACE__ . '\\hide_certificate_attachment_pages', 0);
function hide_certificate_attachment_pages() {
    if (!\is_attachment() || can_manage_certificates()) {
        return;
    }

    if (\get_post_meta(\get_queried_object_id(), META_CERTIFICATE, true)) {
        global $wp_query;
        $wp_query->set_404();
        \status_header(404);
        \nocache_headers();
    }
}
