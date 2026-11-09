<?php
/**
 * Keeps Certificates out of the Media Library unless the user chooses to see
 * them. The choice is per user and covers the list view, the grid view and
 * the media picker on other screens.
 */

namespace Schrauger\DonorThankYou;

\defined('ABSPATH') || exit;

const META_USER_SHOWS_CERTIFICATES = 'donor_show_certificates';

function user_shows_certificates(): bool {
    return (bool) \get_user_meta(\get_current_user_id(), META_USER_SHOWS_CERTIFICATES, true);
}

function without_certificates(array $meta_query): array {
    $meta_query[] = ['key' => META_CERTIFICATE, 'compare' => 'NOT EXISTS'];

    return $meta_query;
}

\add_action('pre_get_posts', __NAMESPACE__ . '\\hide_certificates_from_media_list');
function hide_certificates_from_media_list(\WP_Query $query) {
    global $pagenow;

    if (\is_admin() && 'upload.php' === $pagenow && $query->is_main_query() && !user_shows_certificates()) {
        $query->set('meta_query', without_certificates($query->get('meta_query') ?: []));
    }
}

// Serves the grid view and the media picker.
\add_filter('ajax_query_attachments_args', __NAMESPACE__ . '\\hide_certificates_from_media_grid');
function hide_certificates_from_media_grid(array $query): array {
    // Editors need them on a Donor Message screen to insert the certificate link.
    $picking_for_message = CPT_SLUG === \get_post_type(\absint($_REQUEST['post_id'] ?? 0));

    if (!$picking_for_message && !user_shows_certificates()) {
        $query['meta_query'] = without_certificates($query['meta_query'] ?? []);
    }

    return $query;
}

\add_action('load-upload.php', __NAMESPACE__ . '\\save_certificate_visibility');
function save_certificate_visibility() {
    $choice = $_GET['donor_certificates'] ?? '';

    if (!\in_array($choice, ['show', 'hide'], true)) {
        return;
    }

    \check_admin_referer('donor_certificates');
    \update_user_meta(\get_current_user_id(), META_USER_SHOWS_CERTIFICATES, 'show' === $choice ? '1' : '');
    \wp_safe_redirect(\admin_url('upload.php'));
    exit;
}

\add_action('admin_notices', __NAMESPACE__ . '\\render_certificate_visibility_notice');
function render_certificate_visibility_notice() {
    $screen = \get_current_screen();

    if (!$screen || 'upload' !== $screen->id || !can_manage_certificates()) {
        return;
    }

    $showing = user_shows_certificates();
    $url     = \wp_nonce_url(\admin_url('upload.php?donor_certificates=' . ($showing ? 'hide' : 'show')), 'donor_certificates');

    \printf(
        '<div class="notice notice-info"><p>%s <a href="%s">%s</a></p></div>',
        \esc_html($showing ? __('Donor certificates are shown here.', 'donor-thank-you') : __('Donor certificates are hidden here.', 'donor-thank-you')),
        \esc_url($url),
        \esc_html($showing ? __('Hide them', 'donor-thank-you') : __('Show them', 'donor-thank-you'))
    );
}
