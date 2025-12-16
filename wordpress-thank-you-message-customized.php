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

namespace Schrauger\DonorThankYou;

\defined('ABSPATH') || exit;

// -------------------------
// Plugin constants
// -------------------------
const CPT_SLUG        = 'donor_message';
const SHORTCODE_SLUG  = 'donor_message';
const BLOCK_NAMESPACE = 'donor-thank-you';

// create the CPT
add_action('init', __NAMESPACE__ . '\\register_cpt', 0);
function register_cpt() {
    register_post_type(CPT_SLUG, [
        'labels' => [
            'name'          => __('Donor Messages', 'donor-thank-you'),
            'singular_name' => __('Donor Message', 'donor-thank-you'),
        ],
        'public'  => false, // this cpt is used kind of like a database table, so don't show it publicly
        'show_ui' => true,
        'menu_icon' => 'dashicons-heart',
        'supports' => ['title', 'editor', 'revisions'],
    ]);
}

// save Editor donor information
add_action('save_post_' . CPT_SLUG, __NAMESPACE__ . '\\generate_donor_token');
function generate_donor_token($post_id) {
    // avoid autosave / revisions
    if (\defined('DOING_AUTOSAVE') && DOING_AUTOSAVE) return;

    if (!\get_post_meta($post_id, '_donor_token', true)) {
        \update_post_meta($post_id, '_donor_token', \bin2hex(\random_bytes(16)));
    }
}

// Editor side meta box, to show the generated url to the Editor to copy and paste or use elsewhere
add_action('add_meta_boxes', __NAMESPACE__ . '\\add_donor_meta_box');
function add_donor_meta_box() {
    add_meta_box(
        'donor_link_meta',
        __('Donor Link', 'donor-thank-you'),
        __NAMESPACE__ . '\\render_donor_meta_box',
        CPT_SLUG,
        'side'
    );
}

function render_donor_meta_box($post) {
    $page_path = \get_option('donor_thank_you_page_path', '/thank-you');
    $token = \get_post_meta($post->ID, '_donor_token', true);
    if ($token) {
        $url = site_url($page_path . '?donorid=' . $token);
        echo '<input type="text" readonly style="width:100%" value="' . \esc_attr($url) . '">';
    }
}

// admin preference to specify page path
add_action('admin_menu', __NAMESPACE__ . '\\add_admin_menu');
function add_admin_menu() {
    add_submenu_page(
        CPT_SLUG,                 // parent slug -> make it appear under CPT menu
        'Donor Settings',         // page title
        'Settings',               // menu title
        'manage_options',         // capability
        'donor_settings',         // menu slug
        __NAMESPACE__ . '\\donor_settings_page'     // callback function
    );
}

function donor_settings_page() {
    // check if form submitted
    if (isset($_POST['donor_settings_nonce']) && \wp_verify_nonce($_POST['donor_settings_nonce'], 'save_donor_settings')) {
        $page_path = \sanitize_text_field($_POST['donor_page_path']);
        update_option('donor_thank_you_page_path', $page_path);
        echo '<div class="updated"><p>Settings saved.</p></div>';
    }

    $current_path = \get_option('donor_thank_you_page_path', '/thank-you');
    ?>
    <div class="wrap">
        <h1>Donor Settings</h1>
        <form method="post">
            <?php \wp_nonce_field('save_donor_settings', 'donor_settings_nonce'); ?>
            <table class="form-table">
                <tr>
                    <th scope="row"><label for="donor_page_path">Thank You Page Path</label></th>
                    <td>
                        <input type="text" name="donor_page_path" id="donor_page_path" value="<?php echo \esc_attr($current_path); ?>" class="regular-text">
                        <p class="description">Enter the relative path of the page used to display thank-you messages (e.g., /thank-you)</p>
                    </td>
                </tr>
            </table>
            <?php \submit_button(); ?>
        </form>
    </div>
    <?php
}



// frontend shortcode rendering
add_shortcode(SHORTCODE_SLUG, __NAMESPACE__ . '\\render_donor_shortcode');
function render_donor_shortcode() {
    // if user doesn't pass in a donor id, then show a generic thank you and a link to donate.
    if (!isset($_GET['donorid'])) {
        return '<p>Thank you for your support! <a href="/donate">Donate here</a>.</p>';
    }

    $token = \sanitize_text_field($_GET['donorid']);

    // check for this donor id.
    $query = new \WP_Query([
        'post_type'  => CPT_SLUG,
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
    $name    = \get_the_title();
    $message = \get_the_content();
    \wp_reset_postdata();
    
    ob_start();
    ?>
    <div class="donor-thank-you">
        <h2>Thank you, <?php echo \esc_html($name); ?>!</h2>
        <div class="donor-message">
            <?php echo \apply_filters('the_content', $message); // render blocks and shortcodes ?>
        </div>    
    </div>
    <?php

    return \ob_get_clean();
}

// add a block so it's easier to add to a page than a shortcode
add_action('init', __NAMESPACE__ . '\\register_donor_block');
function register_donor_block() {
    if (!function_exists('register_block_type')) return;

    register_block_type(BLOCK_NAMESPACE . '/message', [
        'title'           => __('Donor Thank You', 'donor-thank-you'),
        'category'        => 'widgets',
        'icon'            => 'heart',
        'render_callback' => __NAMESPACE__ . '\\render_donor_block',
        'attributes'      => [],
    ]);
}
function render_donor_block($attributes) {
    return do_shortcode('[' . SHORTCODE_SLUG . ']');
}

