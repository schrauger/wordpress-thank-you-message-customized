<?php
/**
 * REST API under donor-thank-you/v1, used by a single service account holding
 * only the API capability. Documented in README.md.
 */

namespace Schrauger\DonorThankYou;

\defined('ABSPATH') || exit;

const REST_NAMESPACE = 'donor-thank-you/v1';
const TOKEN_PATTERN  = '(?P<token>[0-9a-f]{32})';

\add_action('rest_api_init', __NAMESPACE__ . '\\register_api_routes');
function register_api_routes() {
    $route = static fn(string $methods, string $callback) => [
        'methods'             => $methods,
        'callback'            => __NAMESPACE__ . '\\' . $callback,
        'permission_callback' => __NAMESPACE__ . '\\can_use_api',
    ];

    \register_rest_route(REST_NAMESPACE, '/messages', [$route('POST', 'api_create_message')]);
    \register_rest_route(REST_NAMESPACE, '/messages/' . TOKEN_PATTERN, [
        $route('GET', 'api_get_message'),
        // POST as well as PATCH, because shared-host firewalls often block PATCH.
        $route('PATCH, POST', 'api_update_message'),
    ]);
    \register_rest_route(REST_NAMESPACE, '/messages/' . TOKEN_PATTERN . '/pdf', [$route('POST', 'api_reissue_certificate')]);
}

function can_use_api(): bool {
    return \current_user_can(API_CAPABILITY);
}

function bad_request(string $code, string $message): \WP_Error {
    return new \WP_Error($code, $message, ['status' => 400]);
}

function page_url(string $token): string {
    return \home_url(\get_option('donor_thank_you_page_path', '/thank-you') . '?donorid=' . $token);
}

function message_response(int $post_id, bool $created, int $status): \WP_REST_Response {
    $attachment_id = (int) \get_post_meta($post_id, META_PDF_ATTACHMENT, true);
    $token         = (string) \get_post_meta($post_id, META_TOKEN, true);

    return new \WP_REST_Response([
        'id'       => $post_id,
        'token'    => $token,
        'page_url' => page_url($token),
        'pdf_url'  => $attachment_id ? \wp_get_attachment_url($attachment_id) : null,
        'created'  => $created,
    ], $status);
}

/** Puts optional content above the certificate link(s), as on legacy pages. */
function compose_body(string $content, array $links): string {
    return \implode("\n\n", \array_filter(\array_merge([\trim($content)], $links), 'strlen'));
}

function api_create_message(\WP_REST_Request $request) {
    $external_ref = \sanitize_text_field((string) $request->get_param('external_ref'));

    if ('' === $external_ref || \mb_strlen($external_ref) > 191) {
        return bad_request('donor_invalid_external_ref', 'external_ref is required, up to 191 characters.');
    }

    // Check-then-create must be atomic, or concurrent retries would duplicate.
    return with_lock('ref:' . $external_ref, 15, static function () use ($request, $external_ref) {
        $existing = find_message_by_meta(META_EXTERNAL_REF, $external_ref, \array_keys(\get_post_stati()));

        return $existing
            ? message_response($existing, false, 200)
            : create_new_message($request, $external_ref);
    });
}

function create_new_message(\WP_REST_Request $request, string $external_ref) {
    $name = \sanitize_text_field((string) $request->get_param('name'));
    $base = sanitise_filename_base((string) $request->get_param('filename_base'));
    $file = $request->get_file_params()['pdf'] ?? null;

    if ('' === $name) {
        return bad_request('donor_invalid_name', 'name is required.');
    }
    if ('' === $base) {
        return bad_request('donor_invalid_filename_base', 'filename_base is required and must contain letters or numbers.');
    }
    if (null === $file) {
        return bad_request('donor_pdf_missing', 'pdf is required.');
    }

    $valid = validate_pdf($file);
    if (\is_wp_error($valid)) {
        return $valid;
    }

    // Stays a draft until complete, so a failure never leaves a broken page live.
    $post_id = \wp_insert_post(\wp_slash([
        'post_type'   => CPT_SLUG,
        'post_status' => 'draft',
        'post_title'  => $name,
    ]), true);

    if (\is_wp_error($post_id)) {
        return $post_id;
    }

    $token       = (string) \get_post_meta($post_id, META_TOKEN, true);
    $certificate = store_certificate($file, certificate_filename($base, $token, 1));

    if (\is_wp_error($certificate)) {
        \wp_delete_post($post_id, true);
        return $certificate;
    }

    \update_post_meta($post_id, META_PDF_ATTACHMENT, $certificate['id']);
    \update_post_meta($post_id, META_PDF_REVISION, 1);
    \update_post_meta($post_id, META_EXTERNAL_REF, \wp_slash($external_ref));

    $content   = \wp_kses_post((string) $request->get_param('content'));
    $published = \wp_update_post(\wp_slash([
        'ID'           => $post_id,
        'post_status'  => 'publish',
        'post_content' => compose_body($content, [certificate_link($certificate['url'])]),
    ]), true);

    if (\is_wp_error($published)) {
        \wp_delete_attachment($certificate['id'], true);
        \wp_delete_post($post_id, true);
        return $published;
    }

    return message_response($post_id, true, 201);
}

function find_message_by_meta(string $key, string $value, array $statuses): int {
    $ids = \get_posts([
        'post_type'        => CPT_SLUG,
        'post_status'      => $statuses,
        'numberposts'      => 1,
        'fields'           => 'ids',
        'orderby'          => 'ID',
        'order'            => 'ASC',
        'meta_key'         => $key,
        'meta_value'       => $value,
        'suppress_filters' => true,
    ]);

    return $ids ? (int) $ids[0] : 0;
}

/** @return \WP_Post|\WP_Error */
function find_message_by_token(string $token) {
    $statuses = \array_diff(\array_keys(\get_post_stati()), ['trash', 'auto-draft']);
    $post_id  = find_message_by_meta(META_TOKEN, $token, $statuses);

    return $post_id
        ? \get_post($post_id)
        : new \WP_Error('donor_not_found', 'No message has this token.', ['status' => 404]);
}

function api_get_message(\WP_REST_Request $request) {
    $post = find_message_by_token($request['token']);

    return \is_wp_error($post) ? $post : message_response($post->ID, false, 200);
}

/**
 * The link(s) a content update must keep: the tracked Certificate's link, or
 * for an untracked legacy post every PDF link it has.
 */
function links_to_preserve(\WP_Post $post): array {
    $links         = find_pdf_links($post->post_content);
    $attachment_id = (int) \get_post_meta($post->ID, META_PDF_ATTACHMENT, true);

    if ($attachment_id) {
        $links = \array_filter($links, static fn($link) => \attachment_url_to_postid($link['href']) === $attachment_id);
    }

    return \array_column($links, 'html');
}

function api_update_message(\WP_REST_Request $request) {
    return with_lock('token:' . $request['token'], 15, static function () use ($request) {
        $post = find_message_by_token($request['token']);
        if (\is_wp_error($post)) {
            return $post;
        }

        $changes = [];

        if ($request->has_param('name')) {
            $changes['post_title'] = \sanitize_text_field((string) $request->get_param('name'));
            if ('' === $changes['post_title']) {
                return bad_request('donor_invalid_name', 'name cannot be blank.');
            }
        }
        if ($request->has_param('content')) {
            $content                 = \wp_kses_post((string) $request->get_param('content'));
            $changes['post_content'] = compose_body($content, links_to_preserve($post));
        }
        if (!$changes) {
            return bad_request('donor_nothing_to_update', 'Provide name or content.');
        }

        $updated = \wp_update_post(\wp_slash(['ID' => $post->ID] + $changes), true);

        return \is_wp_error($updated) ? $updated : message_response($post->ID, false, 200);
    });
}

function api_reissue_certificate(\WP_REST_Request $request) {
    return with_lock('token:' . $request['token'], 15, static function () use ($request) {
        $post = find_message_by_token($request['token']);

        return \is_wp_error($post) ? $post : reissue_certificate($post, $request);
    });
}

/**
 * Finds the link a Reissue replaces.
 *
 * @return array{link: ?array, attachment_id: int}|\WP_Error
 */
function current_certificate(\WP_Post $post) {
    $links         = find_pdf_links($post->post_content);
    $attachment_id = (int) \get_post_meta($post->ID, META_PDF_ATTACHMENT, true);

    if ($attachment_id) {
        foreach ($links as $link) {
            if (\attachment_url_to_postid($link['href']) === $attachment_id) {
                return ['link' => $link, 'attachment_id' => $attachment_id];
            }
        }

        return ['link' => null, 'attachment_id' => $attachment_id];
    }

    if (\count($links) > 1) {
        return new \WP_Error('donor_multiple_certificates', 'This message links more than one PDF, so the one to replace is ambiguous.', ['status' => 409]);
    }

    return [
        'link'          => $links[0] ?? null,
        'attachment_id' => $links ? \attachment_url_to_postid($links[0]['href']) : 0,
    ];
}

/** Works out the base name from the existing file, minus token and revision. */
function derive_filename_base(array $current, string $token): string {
    if ($current['link']) {
        $filename = \basename((string) \wp_parse_url($current['link']['href'], \PHP_URL_PATH));
    } else {
        $filename = $current['attachment_id'] ? \basename((string) \get_attached_file($current['attachment_id'])) : '';
    }

    $base = (string) \preg_replace('/\.pdf$/i', '', $filename);
    $base = (string) \preg_replace('/-r\d+$/', '', $base);
    $base = sanitise_filename_base(\str_replace($token, '', $base));

    return '' !== $base ? $base : DEFAULT_FILENAME_BASE;
}

function reissue_certificate(\WP_Post $post, \WP_REST_Request $request) {
    $token   = (string) \get_post_meta($post->ID, META_TOKEN, true);
    $current = current_certificate($post);

    if (\is_wp_error($current)) {
        return $current;
    }

    $file = $request->get_file_params()['pdf'] ?? null;
    if (null === $file) {
        return bad_request('donor_pdf_missing', 'pdf is required.');
    }

    $valid = validate_pdf($file);
    if (\is_wp_error($valid)) {
        return $valid;
    }

    if ($request->has_param('filename_base')) {
        $base = sanitise_filename_base((string) $request->get_param('filename_base'));
        if ('' === $base) {
            return bad_request('donor_invalid_filename_base', 'filename_base must contain letters or numbers.');
        }
    } else {
        $base = derive_filename_base($current, $token);
    }

    // Legacy certificates have no recorded revision and count as revision 1.
    $has_certificate = $current['link'] || $current['attachment_id'];
    $revision        = $has_certificate ? \max(1, (int) \get_post_meta($post->ID, META_PDF_REVISION, true)) + 1 : 1;
    $certificate     = store_certificate($file, certificate_filename($base, $token, $revision));

    if (\is_wp_error($certificate)) {
        return $certificate;
    }

    if ($current['link']) {
        $new_link = \str_replace($current['link']['href'], \esc_url($certificate['url']), $current['link']['html']);
        $body     = \str_replace($current['link']['html'], $new_link, $post->post_content);
    } else {
        $body = compose_body($post->post_content, [certificate_link($certificate['url'])]);
    }

    $updated = \wp_update_post(\wp_slash(['ID' => $post->ID, 'post_content' => $body]), true);

    if (\is_wp_error($updated)) {
        \wp_delete_attachment($certificate['id'], true);
        return $updated;
    }

    if ($current['attachment_id']) {
        protect_attachment($current['attachment_id']);
    }

    \update_post_meta($post->ID, META_PDF_ATTACHMENT, $certificate['id']);
    \update_post_meta($post->ID, META_PDF_REVISION, $revision);

    return message_response($post->ID, false, 200);
}
