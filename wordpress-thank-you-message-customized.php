<?php
/*
Plugin Name: Donor Thank You Message
Plugin URI:  https://github.com/schrauger/wordpress-thank-you-message-customized
Description: Adds personalized thank-you pages for donors via CPT and shortcodes.
Version:     1.0
Author:      Stephen Schrauger
Author URI:  https://schrauger.com
Text Domain: donor-thank-you
*/

$cpt_slug = "donor_message";
$cpt_name = "Donor Message";
$shortcode_slug = "donor_message";

// create the CPT
add_action('init', function () use ($cpt_slug) {
    register_post_type($cpt_slug, [
        'labels' => [
            'name' => 'Donor Messages',
            'singular_name' => 'Donor Message',
        ],
        'public' => false, // this cpt is used kind of like a database table, so don't show it publicly
        'show_ui' => true,
        'menu_icon' => 'dashicons-heart',
        'supports' => ['revisions'],
    ]);
});


// add Editor fields
add_action('add_meta_boxes', function () use ($cpt_slug) {
    add_meta_box(
        "${cpt_slug}_meta",
        'Donor Information',
        'render_donor_meta_box',
        $cpt_slug
    );
});

// render the Editor fields
function render_donor_meta_box($post) {
    $name    = get_post_meta($post->ID, '_donor_name', true);
    $message = get_post_meta($post->ID, '_donor_message', true);

    wp_nonce_field('save_donor_meta', 'donor_meta_nonce');
    ?>
    <p>
        <label>Name</label><br>
        <input type="text" name="donor_name" value="<?php echo esc_attr($name); ?>" style="width:100%">
    </p>

    <p>
        <label>Message</label><br>
        <textarea name="donor_message" rows="5" style="width:100%"><?php echo esc_textarea($message); ?></textarea>
    </p>
    <?php
}

// save Editor donor information
add_action("save_post_${cpt_slug}", function ($post_id) {
    if (!isset($_POST['donor_meta_nonce']) ||
        !wp_verify_nonce($_POST['donor_meta_nonce'], 'save_donor_meta')) {
        return;
    }

    if (defined('DOING_AUTOSAVE') && DOING_AUTOSAVE) {
        return;
    }

    if (isset($_POST['donor_name'])) {
        update_post_meta(
            $post_id,
            '_donor_name',
            sanitize_text_field($_POST['donor_name'])
        );
    }

    if (isset($_POST['donor_message'])) {
        update_post_meta(
            $post_id,
            '_donor_message',
            sanitize_textarea_field($_POST['donor_message'])
        );
    }

    // Generate token once
    if (!get_post_meta($post_id, '_donor_token', true)) {
        update_post_meta(
            $post_id,
            '_donor_token',
            bin2hex(random_bytes(16)) // unique id to see custom message. not auto-incremented to prevent guessing and seeing other data.
        );
    }

    // Auto-fill post title from donor name
    $name = sanitize_text_field($_POST['donor_name'] ?? '');
    if ($name) {
        // remove filters to prevent infinite loop
        remove_action("save_post_${cpt_slug}", __FUNCTION__);
        wp_update_post([
            'ID'    => $post_id,
            'post_title' => $name,
        ]);
    }
});

// Editor side meta box, to show the generated url to the Editor to copy and paste or use elsewhere
add_action('add_meta_boxes', function () {
    $page_path = get_option('donor_thank_you_page_path', '/thank-you'); // page path to display on side. '/thank-you' by default (change in CPT->Donor Settings)

    add_meta_box(
        'donor_link_meta',
        'Donor Link',
        function ($post) {
            $token = get_post_meta($post->ID, '_donor_token', true);
            if ($token) {
                $url = site_url($page_path . '?donorid=' . $token);
                echo '<code>' . esc_html($url) . '</code>';
            }
        },
        $cpt_slug,
        'side'
    );
});

// admin preference to specify page path
add_action('admin_menu', function () use ($cpt_slug) {
    add_submenu_page(
        $cpt_slug,                // parent slug -> make it appear under CPT menu
        'Donor Settings',         // page title
        'Settings',               // menu title
        'manage_options',         // capability
        'donor_settings',         // menu slug
        'donor_settings_page'     // callback function
    );
});

function donor_settings_page() {
    // check if form submitted
    if (isset($_POST['donor_settings_nonce']) && wp_verify_nonce($_POST['donor_settings_nonce'], 'save_donor_settings')) {
        $page_path = sanitize_text_field($_POST['donor_page_path']);
        update_option('donor_thank_you_page_path', $page_path);
        echo '<div class="updated"><p>Settings saved.</p></div>';
    }

    $current_path = get_option('donor_thank_you_page_path', '/thank-you');
    ?>
    <div class="wrap">
        <h1>Donor Settings</h1>
        <form method="post">
            <?php wp_nonce_field('save_donor_settings', 'donor_settings_nonce'); ?>
            <table class="form-table">
                <tr>
                    <th scope="row"><label for="donor_page_path">Thank You Page Path</label></th>
                    <td>
                        <input type="text" name="donor_page_path" id="donor_page_path" value="<?php echo esc_attr($current_path); ?>" class="regular-text">
                        <p class="description">Enter the relative path of the page used to display thank-you messages (e.g., /thank-you)</p>
                    </td>
                </tr>
            </table>
            <?php submit_button(); ?>
        </form>
    </div>
    <?php
}



// frontend shortcode rendering
add_shortcode($shortcode_slug, function () {

    // if user doesn't pass in a donor id, then show a generic thank you and a link to donate.
    if (!isset($_GET['donorid'])) {
        return '<p>Thank you for your support! <a href="/donate">Donate here</a>.</p>';
    }

    $token = sanitize_text_field($_GET['donorid']);

    // check for this donor id.
    $query = new WP_Query([
        'post_type'  => $cpt_slug,
        'meta_query' => [
            [
                'key'   => '_donor_token',
                'value' => $token,
            ],
        ],
        'posts_per_page' => 1,
    ]);

    // if the donor id doesn't exist (maybe user is playing around with the id in the url), show the same generic message.
    if (!$query->have_posts()) {
        return '<p>Thank you for your support! <a href="/donate">Donate here</a>.</p>';
    }

    // we found a valid id. get the CPT for that id and grab information to use in the message.
    $query->the_post();
    $name    = get_post_meta(get_the_ID(), '_donor_name', true);
    $message = get_post_meta(get_the_ID(), '_donor_message', true);
    wp_reset_postdata();

    ob_start();
    ?>
    <div class="donor-thank-you">
        <h2>Thank you, <?php echo esc_html($name); ?>!</h2>
        <p><?php echo nl2br(esc_html($message)); ?></p>
    </div>
    <?php

    return ob_get_clean();
});

