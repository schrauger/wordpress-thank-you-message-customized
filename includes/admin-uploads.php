<?php
/**
 * A PDF uploaded from a Donor Message edit screen automatically becomes a
 * Certificate. Direct Media Library uploads carry no message context, so they
 * are left alone.
 */

namespace Schrauger\DonorThankYou;

\defined('ABSPATH') || exit;

/** The Donor Message this upload was started from, if the user may edit it. */
function upload_target_message(): ?\WP_Post {
    $post_id = \absint($_REQUEST['post_id'] ?? 0);

    if (!$post_id || (\defined('REST_REQUEST') && REST_REQUEST)) {
        return null;
    }

    $post = \get_post($post_id);

    return ($post && CPT_SLUG === $post->post_type && \current_user_can('edit_post', $post_id)) ? $post : null;
}

\add_filter('wp_handle_upload_prefilter', __NAMESPACE__ . '\\prepare_certificate_upload');
function prepare_certificate_upload(array $file): array {
    $message = upload_target_message();

    if (!$message || 'pdf' !== \strtolower(\pathinfo($file['name'], \PATHINFO_EXTENSION))) {
        return $file;
    }

    $token = (string) \get_post_meta($message->ID, META_TOKEN, true);
    if ('' === $token) {
        return $file;
    }

    $valid = validate_pdf($file);
    if (\is_wp_error($valid)) {
        $file['error'] = $valid->get_error_message();
        return $file;
    }

    $base     = sanitise_filename_base(\str_replace($token, '', \pathinfo($file['name'], \PATHINFO_FILENAME)));
    $filename = certificate_filename('' !== $base ? $base : DEFAULT_FILENAME_BASE, $token, 1);

    // media_handle_upload() files the upload under the message's own date.
    $upload_time = (int) \substr($message->post_date, 0, 4) > 0 ? $message->post_date : null;

    if (\file_exists(\wp_upload_dir($upload_time)['path'] . '/' . $filename)) {
        $file['error'] = filename_taken()->get_error_message();
        return $file;
    }

    $file['name'] = $filename;

    // One upload per request, so this affects only this Certificate.
    \add_filter('fallback_intermediate_image_sizes', '__return_empty_array');

    return $file;
}

\add_action('add_attachment', __NAMESPACE__ . '\\protect_certificate_upload');
function protect_certificate_upload($attachment_id) {
    $parent = \get_post((int) \wp_get_post_parent_id($attachment_id));

    if (!$parent || CPT_SLUG !== $parent->post_type || 'application/pdf' !== \get_post_mime_type($attachment_id)) {
        return;
    }

    $token = (string) \get_post_meta($parent->ID, META_TOKEN, true);

    if ('' !== $token && false !== \strpos(\basename((string) \get_attached_file($attachment_id)), $token)) {
        protect_attachment((int) $attachment_id);
    }
}
