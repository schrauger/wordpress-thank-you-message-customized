<?php
/**
 * Validates, names and stores Certificate PDFs.
 */

namespace Schrauger\DonorThankYou;

\defined('ABSPATH') || exit;

const FILENAME_BASE_MAX_LENGTH = 80;
const DEFAULT_FILENAME_BASE    = 'Adoption-Certificate';
const CERTIFICATE_LINK_TEXT    = 'Digital copy of your adoption certificate';

function pdf_max_bytes(): int {
    return (int) \apply_filters('donor_thank_you_pdf_max_bytes', 64 * 1024 * 1024);
}

/**
 * Checks what the file contains. The client's MIME type and extension are
 * never consulted.
 *
 * @param array $file An entry from $_FILES.
 * @return true|\WP_Error
 */
function validate_pdf(array $file) {
    $error = (int) ($file['error'] ?? \UPLOAD_ERR_NO_FILE);

    if (\in_array($error, [\UPLOAD_ERR_INI_SIZE, \UPLOAD_ERR_FORM_SIZE], true)) {
        return pdf_too_large();
    }
    if (\UPLOAD_ERR_OK !== $error) {
        return new \WP_Error('donor_pdf_upload_failed', 'The PDF upload failed.', ['status' => 400]);
    }

    $path = $file['tmp_name'];
    $size = (int) \filesize($path);

    if ($size > pdf_max_bytes()) {
        return pdf_too_large();
    }

    $handle = \fopen($path, 'rb');
    $head   = (string) \fread($handle, 5);
    \fseek($handle, -\min(1024, $size), \SEEK_END);
    $tail = (string) \fread($handle, 1024);
    \fclose($handle);

    $type = \class_exists('finfo') ? (new \finfo(\FILEINFO_MIME_TYPE))->file($path) : false;

    if ('%PDF-' !== $head || 'application/pdf' !== $type || false === \strpos($tail, '%%EOF')) {
        return new \WP_Error('donor_pdf_invalid', 'The uploaded file is not a valid PDF.', ['status' => 400]);
    }

    return true;
}

function pdf_too_large(): \WP_Error {
    return new \WP_Error('donor_pdf_too_large', 'The PDF is larger than the allowed size.', ['status' => 413]);
}

/** Reduces a display name to filename-safe characters; may return ''. */
function sanitise_filename_base(string $base): string {
    $base = \remove_accents($base);
    $base = (string) \preg_replace('/\.pdf$/i', '', \trim($base));
    $base = (string) \preg_replace('/[^A-Za-z0-9_-]+/', '-', $base);
    $base = (string) \preg_replace('/-{2,}/', '-', $base);

    return \trim(\substr(\trim($base, '-_'), 0, FILENAME_BASE_MAX_LENGTH), '-_');
}

function certificate_filename(string $base, string $token, int $revision): string {
    return $base . '-' . $token . ($revision > 1 ? '-r' . $revision : '') . '.pdf';
}

function certificate_link(string $url): string {
    return '<a href="' . \esc_url($url) . '">' . CERTIFICATE_LINK_TEXT . '</a>';
}

/**
 * Stores a validated PDF as a private, flagged attachment under exactly the
 * given filename. A name that is already taken is an error: a numeric suffix
 * from wp_unique_filename would break the filename scheme.
 *
 * @return array{id: int, url: string}|\WP_Error
 */
function store_certificate(array $file, string $filename) {
    require_once \ABSPATH . 'wp-admin/includes/file.php';
    require_once \ABSPATH . 'wp-admin/includes/image.php';

    $uploads = \wp_upload_dir();
    if (\file_exists($uploads['path'] . '/' . $filename)) {
        return filename_taken();
    }

    $file['name'] = $filename;
    $file['type'] = 'application/pdf';
    $stored       = \wp_handle_upload($file, ['test_form' => false, 'mimes' => ['pdf' => 'application/pdf']]);

    if (isset($stored['error'])) {
        return new \WP_Error('donor_pdf_store_failed', $stored['error'], ['status' => 500]);
    }
    if (\basename($stored['file']) !== $filename) {
        \wp_delete_file($stored['file']);
        return filename_taken();
    }

    $attachment_id = \wp_insert_attachment([
        'post_title'     => \pathinfo($filename, \PATHINFO_FILENAME),
        'post_mime_type' => 'application/pdf',
        'post_status'    => 'private',
        'guid'           => $stored['url'],
    ], $stored['file'], 0, true);

    if (\is_wp_error($attachment_id)) {
        \wp_delete_file($stored['file']);
        return $attachment_id;
    }

    \update_post_meta($attachment_id, META_CERTIFICATE, '1');

    // Preview images would run Imagick on untrusted input.
    \add_filter('fallback_intermediate_image_sizes', '__return_empty_array');
    \wp_update_attachment_metadata($attachment_id, \wp_generate_attachment_metadata($attachment_id, $stored['file']));
    \remove_filter('fallback_intermediate_image_sizes', '__return_empty_array');

    return ['id' => (int) $attachment_id, 'url' => (string) \wp_get_attachment_url($attachment_id)];
}

function filename_taken(): \WP_Error {
    return new \WP_Error('donor_pdf_filename_taken', 'A certificate with this filename already exists.', ['status' => 409]);
}
