#!/usr/bin/env bash
#
# Integration tests for the Donor Thank You plugin. Needs only bash, curl and
# WP-CLI, and runs against a disposable local site with synthetic records.
#
#   WP_URL=http://localhost:8080 \
#   WP_CLI="docker compose --project-directory /path/to/site run --rm -T cli wp" \
#   tests/integration.sh [slice ...]
#
# Slices default to all of them. Output carries counts and synthetic values
# only, so it is safe to run on a copy holding real Donor Messages.

set -u

WP_URL="${WP_URL:-http://localhost:8080}"
WP_CLI="${WP_CLI:-wp}"
API="$WP_URL/wp-json/donor-thank-you/v1"
WORK="$(mktemp -d)"
PASSED=0
FAILED=0

# ---- harness ---------------------------------------------------------------

wp_cli() { $WP_CLI "$@" 2>/dev/null; }

# Runs PHP from stdin inside WordPress; extra arguments arrive in $args.
wp_php() { $WP_CLI eval-file - "$@" 2>/dev/null; }

pass() { PASSED=$((PASSED + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; return 0; }

assert_eq() { # label expected actual
	if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2], got [$3]"; fi
}
assert_ne() { # label unexpected actual
	if [ "$2" != "$3" ]; then pass "$1"; else fail "$1" "did not expect [$3]"; fi
}
assert_match() { # label extended-regex text
	if printf '%s' "$3" | tr '\n' ' ' | grep -Eq -- "$2"; then pass "$1"; else fail "$1" "no match for [$2]"; fi
}
assert_no_match() { # label extended-regex text
	if printf '%s' "$3" | tr '\n' ' ' | grep -Eq -- "$2"; then fail "$1" "unexpected match for [$2]"; else pass "$1"; fi
}
# Bodies here can hold real filenames, so a failure must not print them.
assert_empty_list() { # label body
	if [ "$2" = "[]" ]; then pass "$1"; else fail "$1" "response was not an empty list"; fi
}
assert_denied() { # label status: anonymous access must be refused
	case "$2" in 401|403|404) pass "$1" ;; *) fail "$1" "expected 401, 403 or 404, got [$2]" ;; esac
}

# Sets STATUS, BODY and HEADERS. Remaining arguments go straight to curl.
http() { # METHOD URL [curl args]
	local method="$1" url="$2"
	shift 2
	STATUS="$(curl -gs -X "$method" -D "$WORK/headers" -o "$WORK/body" -w '%{http_code}' "$@" "$url")"
	BODY="$(cat "$WORK/body")"
	HEADERS="$(tr -d '\r' < "$WORK/headers")"
}

# Reads one flat field from a JSON response, without needing a JSON parser.
json_field() { # key [json]
	printf '%s' "${2:-$BODY}" | sed -nE "s/.*\"$1\":\"?([^\",}]*)\"?.*/\1/p" | sed 's#\\/#/#g'
}

header() { printf '%s\n' "$HEADERS" | sed -nE "s/^$1: *//Ip" | tail -n 1; }

make_pdf() { # path [padding bytes]
	printf '%%PDF-1.4\n1 0 obj\n<<>>\nendobj\n' > "$1"
	[ -n "${2:-}" ] && head -c "$2" /dev/zero | tr '\0' ' ' >> "$1"
	printf 'trailer\n<<>>\n%%%%EOF\n' >> "$1"
}

# Removes every synthetic record, including any left by an aborted run.
sweep() {
	wp_php <<'PHP'
<?php
global $wpdb;
foreach ($wpdb->get_col("SELECT ID FROM {$wpdb->posts} WHERE post_type='donor_message' AND post_title LIKE 'Itest %'") as $id) {
	wp_delete_post((int) $id, true);
}
foreach ($wpdb->get_col("SELECT ID FROM {$wpdb->posts} WHERE post_type='attachment' AND post_title LIKE 'itest-%'") as $id) {
	wp_delete_attachment((int) $id, true);
}
foreach (get_users(['search' => 'itest_*', 'search_columns' => ['user_login']]) as $user) {
	require_once ABSPATH . 'wp-admin/includes/user.php';
	wp_delete_user($user->ID);
}
PHP
}

cleanup() { sweep; rm -rf "$WORK"; }

guard_local_site() {
	local env
	env="$(wp_cli eval 'echo wp_get_environment_type();')"
	if [ "$env" != "local" ]; then
		echo "Refusing to run: WordPress reports environment type [$env], not [local]." >&2
		rm -rf "$WORK"
		exit 2
	fi
}

# Forces the once-only upgrade to run again, through a real web request.
rerun_upgrade() {
	wp_cli option delete donor_thank_you_schema_version >/dev/null
	curl -gs -o /dev/null "$WP_URL/wp-json/"
}

# ---- fixtures --------------------------------------------------------------

# Creates messages shaped like hand-made legacy ones: unparented attachments
# with status inherit. Prints: shape post attachment token url [att2 url2]
legacy_fixtures() {
	wp_php <<'PHP'
<?php
function itest_attachment($token, $suffix) {
	$dir  = wp_upload_dir();
	$name = "itest-Adoption-Certificate{$suffix}-{$token}.pdf";
	$path = $dir['path'] . '/' . $name;
	file_put_contents($path, "%PDF-1.4\n1 0 obj\n<<>>\nendobj\ntrailer\n<<>>\n%%EOF\n");
	$id = wp_insert_attachment([
		'post_title'     => pathinfo($name, PATHINFO_FILENAME),
		'post_mime_type' => 'application/pdf',
		'post_status'    => 'inherit',
		'guid'           => $dir['url'] . '/' . $name,
	], $path);
	return [$id, $dir['url'] . '/' . $name];
}
$wording = 'Digital copy of your adoption certificate';
foreach (['single', 'blank', 'double', 'none'] as $shape) {
	$post  = wp_insert_post(['post_type' => 'donor_message', 'post_status' => 'publish', 'post_title' => "Itest Legacy $shape"]);
	$token = get_post_meta($post, '_donor_token', true);
	$line  = "$shape $post";
	$body  = 'Thank you for your donation!';
	if ('none' !== $shape) {
		[$att, $url] = itest_attachment($token, '');
		$attr = 'blank' === $shape ? ' target="_blank" rel="noopener"' : '';
		$body = "<a href=\"$url\"$attr>$wording</a>";
		$line = "$shape $post $att $token $url";
		if ('double' === $shape) {
			[$att2, $url2] = itest_attachment($token, '-two');
			$body .= " and <a href=\"$url2\">$wording</a>";
			$line .= " $att2 $url2";
		}
	} else {
		$line = "$shape $post 0 $token -";
	}
	wp_update_post(['ID' => $post, 'post_content' => $body]);
	echo $line, "\n";
}
PHP
}

load_legacy_fixtures() {
	local shape post att token url att2 url2
	while read -r shape post att token url att2 url2; do
		L_POST[$shape]="$post"; L_ATT[$shape]="$att"; L_TOKEN[$shape]="$token"; L_URL[$shape]="$url"
		L_ATT2[$shape]="${att2:-}"; L_URL2[$shape]="${url2:-}"
	done < <(legacy_fixtures)
}
declare -A L_POST L_ATT L_TOKEN L_URL L_ATT2 L_URL2

# Everything about an attachment and its message except the status and flags.
fingerprint() { # attachment-id post-id
	wp_php "$1" "$2" <<'PHP'
<?php
global $wpdb;
[$att, $post] = array_map('intval', $args);
$a = $wpdb->get_row($wpdb->prepare("SELECT post_name, guid, post_modified, post_title, post_parent FROM {$wpdb->posts} WHERE ID=%d", $att), ARRAY_A);
$p = $wpdb->get_row($wpdb->prepare("SELECT post_content, post_title, post_modified FROM {$wpdb->posts} WHERE ID=%d", $post), ARRAY_A);
echo sha1(implode('|', $a) . '|' . get_post_meta($att, '_wp_attached_file', true) . '|' . sha1_file(get_attached_file($att)) . '|' . implode('|', $p));
PHP
}

att_state() { # attachment-id -> "status flag"
	wp_php "$1" <<'PHP'
<?php
echo get_post_field('post_status', (int) $args[0]), ' ', get_post_meta((int) $args[0], '_donor_certificate', true) ?: 'unflagged';
PHP
}

# ---- slices ----------------------------------------------------------------

t_backfill() {
	echo "backfill"
	load_legacy_fixtures
	assert_eq "fixture starts public" "inherit unflagged" "$(att_state "${L_ATT[single]}")"

	local before after again
	before="$(fingerprint "${L_ATT[single]}" "${L_POST[single]}")"
	rerun_upgrade

	assert_eq "single-link certificate is private and flagged" "private 1" "$(att_state "${L_ATT[single]}")"
	assert_eq "target=_blank certificate is private and flagged" "private 1" "$(att_state "${L_ATT[blank]}")"
	assert_eq "first of two certificates is private and flagged" "private 1" "$(att_state "${L_ATT[double]}")"
	assert_eq "second of two certificates is private and flagged" "private 1" "$(att_state "${L_ATT2[double]}")"

	after="$(fingerprint "${L_ATT[single]}" "${L_POST[single]}")"
	assert_eq "file, name, GUID, dates and body are unchanged" "$before" "$after"

	assert_eq "single-link post tracks its certificate" "${L_ATT[single]}" "$(wp_cli post meta get "${L_POST[single]}" _donor_pdf_attachment_id)"
	assert_eq "two-link post tracks no certificate" "" "$(wp_cli post meta get "${L_POST[double]}" _donor_pdf_attachment_id)"

	rerun_upgrade
	again="$(fingerprint "${L_ATT[single]}" "${L_POST[single]}")"
	assert_eq "running the backfill again changes nothing" "$after" "$again"

	http GET "${L_URL[single]}"
	assert_eq "exact PDF URL stays anonymously reachable" "200" "$STATUS"

	local exposed
	exposed="$(wp_php <<'PHP'
<?php
// Every PDF linked from any message, real or synthetic, must be protected.
$bad = 0;
foreach (get_posts(['post_type' => 'donor_message', 'post_status' => array_keys(get_post_stati()), 'numberposts' => -1]) as $p) {
	preg_match_all('~href=["\']([^"\']+\.pdf)["\']~i', $p->post_content, $m);
	foreach ($m[1] as $url) {
		$id = attachment_url_to_postid($url);
		if (!$id || 'private' !== get_post_status($id) || '1' !== get_post_meta($id, '_donor_certificate', true)) {
			$bad++;
		}
	}
}
echo $bad;
PHP
)"
	assert_eq "no linked certificate on the site is left unprotected" "0" "$exposed"
}

t_anonymous_exposure() {
	echo "anonymous exposure"
	load_legacy_fixtures
	rerun_upgrade
	local att="${L_ATT[single]}" name
	name="$(basename "${L_URL[single]}" .pdf)"

	http GET "$WP_URL/wp-json/wp/v2/media?search=$name"
	assert_empty_list "media search by filename finds nothing" "$BODY"
	assert_eq "media search total is zero" "0" "$(header X-WP-Total)"

	http GET "$WP_URL/wp-json/wp/v2/media?search=Adoption-Certificate"
	assert_empty_list "media search for the certificate wording is empty" "$BODY"
	assert_eq "X-WP-Total does not count certificates" "0" "$(header X-WP-Total)"

	http GET "$WP_URL/wp-json/wp/v2/media?mime_type=application/pdf&per_page=100"
	assert_no_match "PDF media listing omits certificates" "Adoption-Certificate" "$BODY"

	http GET "$WP_URL/wp-json/wp/v2/media?per_page=100"
	assert_no_match "full media listing omits certificates" "Adoption-Certificate" "$BODY"

	http GET "$WP_URL/wp-json/wp/v2/media/$att"
	assert_denied "single media item is refused" "$STATUS"

	http GET "$WP_URL/?attachment_id=$att" -L
	assert_eq "attachment page by ID is 404" "404" "$STATUS"
	assert_no_match "attachment page does not reveal the file" "$name" "$BODY"

	http GET "$WP_URL/?p=$att" -L
	assert_eq "attachment page by post ID is 404" "404" "$STATUS"

	http GET "$WP_URL/$name/" -L
	assert_eq "attachment page by slug is 404" "404" "$STATUS"
	assert_no_match "slug URL does not reveal the file" "$name" "$BODY"

	http GET "$WP_URL/wp-json/wp/v2/search?search=$name"
	assert_empty_list "REST search finds nothing" "$BODY"

	http GET "$WP_URL/wp-json/wp/v2/donor_message"
	assert_eq "message post type is not in REST" "404" "$STATUS"

	http GET "$WP_URL/?s=$name"
	assert_no_match "front-end search does not link certificates" "$name\.pdf" "$BODY"

	http GET "$WP_URL/?feed=rss2"
	assert_no_match "feed omits certificates" "Adoption-Certificate" "$BODY"

	http GET "$WP_URL/wp-sitemap.xml" -L
	assert_no_match "sitemap omits certificates" "Adoption-Certificate" "$BODY"

	http GET "$WP_URL/wp-content/uploads/$(date +%Y/%m)/"
	assert_no_match "upload directory does not list certificates" "Adoption-Certificate" "$BODY"
}

t_token_requests() {
	echo "token requests"
	load_legacy_fixtures
	rerun_upgrade
	local page
	page="$WP_URL$(wp_cli option get donor_thank_you_page_path)/"

	http GET "$page?donorid=${L_TOKEN[single]}"
	assert_eq "Donor Link loads" "200" "$STATUS"
	assert_match "response is not cacheable" "no-store|no-cache" "$(header Cache-Control)"
	assert_eq "referrer is limited to this site" "same-origin" "$(header Referrer-Policy)"
	assert_match "page is noindex" "<meta name=.robots. content=.[^>]*noindex" "$BODY"
	assert_match "page asks not to be archived" "<meta name=.robots. content=.[^>]*noarchive" "$BODY"
	assert_match "links on the page are not followed" "<meta name=.robots. content=.[^>]*nofollow" "$BODY"
	assert_eq "robots header covers the page" "noindex, nofollow, noarchive" "$(header X-Robots-Tag)"
	assert_match "legacy page shows the donor's name" "Itest Legacy single" "$BODY"
	assert_match "legacy page keeps its certificate link" "<a href=\"${L_URL[single]}\">Digital copy of your adoption certificate</a>" "$BODY"

	http GET "$page?donorid=${L_TOKEN[blank]}"
	assert_match "target=_blank link renders as before" "target=\"_blank\"" "$BODY"

	http GET "$page?donorid=${L_TOKEN[none]}"
	assert_match "legacy page with no certificate renders" "Thank you for your donation!" "$BODY"

	http GET "$page?donorid=00000000000000000000000000000000"
	assert_eq "unknown token still loads" "200" "$STATUS"
	assert_no_match "unknown token shows no donor" "donor-thank-you\"" "$BODY"
	assert_eq "unknown token is protected too" "same-origin" "$(header Referrer-Policy)"

	http GET "$page"
	assert_eq "page without a token has no referrer header" "" "$(header Referrer-Policy)"
	assert_eq "page without a token has no robots header" "" "$(header X-Robots-Tag)"

	assert_eq "token requests opt out of page caching" "yes" "$(wp_php <<'PHP'
<?php
$_GET['donorid'] = 'x';
do_action('send_headers', $GLOBALS['wp']);
echo defined('DONOTCACHEPAGE') && DONOTCACHEPAGE ? 'yes' : 'no';
PHP
)"
}

# ---- API helpers -----------------------------------------------------------

SERVICE_AUTH=""
EDITOR_AUTH=""
FIXTURE_PDF="$WORK/certificate.pdf"

# Application Passwords are held in variables and never printed.
api_users() {
	[ -n "$SERVICE_AUTH" ] && return 0
	local password
	wp_cli user create itest_service itest_service@example.invalid --role=donor_api_service --porcelain >/dev/null
	password="$(wp_cli user application-password create itest_service itest --porcelain)"
	SERVICE_AUTH="itest_service:$password"
	wp_cli user create itest_editor itest_editor@example.invalid --role=editor --porcelain >/dev/null
	password="$(wp_cli user application-password create itest_editor itest --porcelain)"
	EDITOR_AUTH="itest_editor:$password"
	make_pdf "$FIXTURE_PDF"
}

# Time-based because callers use $(next_ref), where a counter would not persist.
next_ref() { printf 'itest:%s-%s' "$$" "$(date +%s%N)"; }

create_message() { # name external_ref [extra curl args]
	local name="$1" ref="$2"
	shift 2
	http POST "$API/messages" -u "$SERVICE_AUTH" --form-string "name=$name" --form-string "external_ref=$ref" \
		-F "filename_base=itest-Adoption-Certificate" -F "pdf=@$FIXTURE_PDF;type=application/pdf" "$@"
}

message_count() {
	wp_php <<'PHP'
<?php
global $wpdb;
echo (int) $wpdb->get_var("SELECT COUNT(*) FROM {$wpdb->posts} WHERE post_type='donor_message' AND post_title LIKE 'Itest %'");
PHP
}

post_content() { wp_cli post get "$1" --field=post_content; }

t_api_auth() {
	echo "API authentication"
	api_users
	local token="0123456789abcdef0123456789abcdef" route method path
	for route in "POST /messages" "GET /messages/$token" "PATCH /messages/$token" "POST /messages/$token" "POST /messages/$token/pdf"; do
		method="${route% *}"; path="${route#* }"
		http "$method" "$API$path"
		assert_eq "anonymous is refused: ${route/$token/{token\}}" "401" "$STATUS"
		http "$method" "$API$path" -u "$EDITOR_AUTH"
		assert_eq "wrong role is refused: ${route/$token/{token\}}" "403" "$STATUS"
		http "$method" "$API$path" -u "itest_service:not-the-password"
		assert_denied "wrong password is refused: ${route/$token/{token\}}" "$STATUS"
	done
	assert_eq "service role holds only the API capability" "manage_donor_messages_api" \
		"$(wp_php <<'PHP'
<?php
echo implode(',', array_keys(array_filter(get_role('donor_api_service')->capabilities)));
PHP
)"
}

t_api_create() {
	echo "API create"
	api_users
	create_message "Itest O'Brien \"Quoted\"" "$(next_ref)" --form-string 'content=<p>Hello <strong>there</strong></p><script>alert(1)</script>'
	assert_eq "new message returns 201" "201" "$STATUS"
	assert_eq "created is true" "true" "$(json_field created)"
	local id token page_url pdf_url
	id="$(json_field id)"; token="$(json_field token)"; page_url="$(json_field page_url)"; pdf_url="$(json_field pdf_url)"
	assert_match "token is 32 hex characters" "^[0-9a-f]{32}$" "$token"
	assert_eq "page_url is the Donor Link" "$WP_URL/thank-you?donorid=$token" "$page_url"
	assert_match "filename is base plus token" "/itest-Adoption-Certificate-$token\.pdf$" "$pdf_url"
	assert_eq "message is published at once" "publish" "$(wp_cli post get "$id" --field=post_status)"
	assert_eq "name keeps its punctuation unslashed" "Itest O'Brien \"Quoted\"" "$(wp_cli post get "$id" --field=post_title)"

	local body
	body="$(post_content "$id")"
	assert_match "optional content comes first" "^<p>Hello <strong>there</strong></p>" "$body"
	assert_no_match "script is stripped from content" "<script" "$body"
	assert_match "body ends with the standard link" "<a href=\"$pdf_url\">Digital copy of your adoption certificate</a>$" "$body"

	http GET "$pdf_url"
	assert_eq "certificate is reachable at its URL" "200" "$STATUS"
	assert_eq "stored file matches the upload" "$(sha1sum < "$FIXTURE_PDF")" "$(sha1sum < "$WORK/body")"

	local att
	att="$(wp_cli post meta get "$id" _donor_pdf_attachment_id)"
	assert_eq "attachment is private and flagged" "private 1" "$(att_state "$att")"
	assert_eq "no PDF preview images are generated" "0" "$(wp_php "$att" <<'PHP'
<?php
echo count(wp_get_attachment_metadata((int) $args[0])['sizes'] ?? []);
PHP
)"

	http GET "$WP_URL/thank-you/?donorid=$token"
	assert_match "Donor Link shows the certificate" "$pdf_url" "$BODY"

	http GET "$WP_URL/wp-json/wp/v2/media?search=$token"
	assert_empty_list "new certificate is hidden from the media API" "$BODY"

	http POST "$API/messages" -u "$SERVICE_AUTH" -F "name=Itest Slug" -F "external_ref=$(next_ref)" \
		-F 'filename_base=../../itest Évil name!.php' -F "pdf=@$FIXTURE_PDF"
	assert_eq "hostile filename base is accepted once cleaned" "201" "$STATUS"
	token="$(json_field token)"
	assert_match "hostile filename base is sanitised" "/[A-Za-z0-9_-]+-$token\.pdf$" "$(json_field pdf_url)"
	assert_no_match "no path traversal or php in the name" "\.\.|\.php" "$(json_field pdf_url)"

	local long
	long="itest$(printf 'a%.0s' $(seq 1 400))"
	http POST "$API/messages" -u "$SERVICE_AUTH" -F "name=Itest Long" -F "external_ref=$(next_ref)" \
		-F "filename_base=$long" -F "pdf=@$FIXTURE_PDF"
	assert_eq "long filename base is accepted" "201" "$STATUS"
	assert_match "long filename base is capped" "/itesta{1,75}-$(json_field token)\.pdf$" "$(json_field pdf_url)"
}

t_pdf_rejection() {
	echo "PDF rejection"
	api_users
	local before text="$WORK/not-a.pdf" png="$WORK/image.pdf" late="$WORK/late.pdf" cut="$WORK/cut.pdf" big="$WORK/big.pdf" ok="$WORK/limit.pdf"
	before="$(message_count)"
	printf 'plain text, not a document\n%%%%EOF\n' > "$text"
	printf '\x89PNG\r\n\x1a\n0000000000000000%%%%EOF\n' > "$png"
	{ printf 'junk!'; cat "$FIXTURE_PDF"; } > "$late"
	printf '%%PDF-1.4\n1 0 obj\n<<>>\nendobj\n' > "$cut"
	make_pdf "$big" $((64 * 1024 * 1024 + 1))

	reject() { # label expected-status file
		http POST "$API/messages" -u "$SERVICE_AUTH" -F "name=Itest Rejected" -F "external_ref=$(next_ref)" \
			-F "filename_base=itest-Adoption-Certificate" -F "pdf=@$3;type=application/pdf"
		assert_eq "$1" "$2" "$STATUS"
	}
	reject "renamed non-PDF is refused" 400 "$text"
	reject "spoofed MIME type is refused" 400 "$png"
	reject "header not at offset 0 is refused" 400 "$late"
	reject "missing end marker is refused" 400 "$cut"
	reject "file over 64 MB is refused" 413 "$big"

	http POST "$API/messages" -u "$SERVICE_AUTH" -F "name=Itest Rejected" -F "external_ref=$(next_ref)" -F "filename_base=itest-x"
	assert_eq "missing PDF is refused" "400" "$STATUS"
	http POST "$API/messages" -u "$SERVICE_AUTH" -F "name=Itest Rejected" -F "filename_base=itest-x" -F "pdf=@$FIXTURE_PDF"
	assert_eq "missing external_ref is refused" "400" "$STATUS"
	http POST "$API/messages" -u "$SERVICE_AUTH" -F "external_ref=$(next_ref)" -F "filename_base=itest-x" -F "pdf=@$FIXTURE_PDF"
	assert_eq "missing name is refused" "400" "$STATUS"
	http POST "$API/messages" -u "$SERVICE_AUTH" -F "name=Itest Rejected" -F "external_ref=$(next_ref)" -F 'filename_base=!!!' -F "pdf=@$FIXTURE_PDF"
	assert_eq "filename base with nothing usable is refused" "400" "$STATUS"
	assert_eq "rejected uploads create no messages" "$before" "$(message_count)"

	make_pdf "$ok" $((1024 * 1024))
	http POST "$API/messages" -u "$SERVICE_AUTH" -F "name=Itest Sized" -F "external_ref=$(next_ref)" -F "filename_base=itest-Adoption-Certificate" -F "pdf=@$ok"
	assert_eq "a valid larger PDF is accepted" "201" "$STATUS"
}

t_idempotency() {
	echo "idempotency"
	api_users
	local ref id token
	ref="$(next_ref)"
	create_message "Itest Original" "$ref"
	assert_eq "first request creates" "201" "$STATUS"
	id="$(json_field id)"; token="$(json_field token)"

	http POST "$API/messages" -u "$SERVICE_AUTH" -F "name=Itest Changed" -F "external_ref=$ref"
	assert_eq "replay returns 200" "200" "$STATUS"
	assert_eq "replay says not created" "false" "$(json_field created)"
	assert_eq "replay returns the same token" "$token" "$(json_field token)"
	assert_eq "replay ignores the payload" "Itest Original" "$(wp_cli post get "$id" --field=post_title)"

	local ref2 i
	ref2="$(next_ref)"
	for i in 1 2 3 4 5 6 7 8; do
		curl -gs -o /dev/null -w '%{http_code}\n' -u "$SERVICE_AUTH" -F "name=Itest Concurrent" -F "external_ref=$ref2" \
			-F "filename_base=itest-Adoption-Certificate" -F "pdf=@$FIXTURE_PDF" "$API/messages" > "$WORK/concurrent.$i" &
	done
	wait
	assert_eq "concurrent retries create exactly once" "1" "$(cat "$WORK"/concurrent.* | grep -c '^201$')"
	assert_eq "the other concurrent retries replay" "7" "$(cat "$WORK"/concurrent.* | grep -c '^200$')"
	assert_eq "concurrent retries leave one message" "1" "$(wp_php "$ref2" <<'PHP'
<?php
global $wpdb;
echo (int) $wpdb->get_var($wpdb->prepare("SELECT COUNT(*) FROM {$wpdb->postmeta} WHERE meta_key='_donor_external_ref' AND meta_value=%s", $args[0]));
PHP
)"

	local first_token
	create_message "Itest Case A" "itest:case-$$"
	first_token="$(json_field token)"
	create_message "Itest Case B" "itest:CASE-$$"
	assert_eq "External References differing only in case are distinct" "201" "$STATUS"
	assert_ne "a differently cased reference gets its own token" "$first_token" "$(json_field token)"

	wp_cli post delete "$id" >/dev/null
	http POST "$API/messages" -u "$SERVICE_AUTH" -F "name=Itest Again" -F "external_ref=$ref"
	assert_eq "a trashed message still answers a retry" "200" "$STATUS"
	assert_eq "retry after trashing returns the same record" "$id" "$(json_field id)"
}

t_read_update() {
	echo "read and update"
	api_users
	local id token url body
	create_message "Itest Update" "$(next_ref)" --form-string 'content=<p>First</p>'
	id="$(json_field id)"; token="$(json_field token)"; url="$(json_field pdf_url)"

	http GET "$API/messages/$token" -u "$SERVICE_AUTH"
	assert_eq "fetch returns 200" "200" "$STATUS"
	assert_eq "fetch returns the record" "$id" "$(json_field id)"
	assert_eq "fetch returns the certificate URL" "$url" "$(json_field pdf_url)"
	assert_eq "fetch says not created" "false" "$(json_field created)"

	http GET "$API/messages/0123456789abcdef0123456789abcdef" -u "$SERVICE_AUTH"
	assert_eq "unknown token is 404" "404" "$STATUS"
	http GET "$API/messages/not-a-token" -u "$SERVICE_AUTH"
	assert_eq "malformed token matches no route" "404" "$STATUS"

	http PATCH "$API/messages/$token" -u "$SERVICE_AUTH" -H 'Content-Type: application/json' -d '{"name":"Itest Renamed"}'
	assert_eq "PATCH name returns 200" "200" "$STATUS"
	assert_eq "PATCH changes the name" "Itest Renamed" "$(wp_cli post get "$id" --field=post_title)"
	assert_match "PATCH name leaves the body alone" "^<p>First</p>" "$(post_content "$id")"

	http PATCH "$API/messages/$token" -u "$SERVICE_AUTH" -H 'Content-Type: application/json' -d '{"content":"<p>Second</p>"}'
	body="$(post_content "$id")"
	assert_match "PATCH replaces the content" "^<p>Second</p>" "$body"
	assert_no_match "PATCH removes the old content" "First" "$body"
	assert_match "PATCH keeps the certificate link" "<a href=\"$url\">Digital copy of your adoption certificate</a>$" "$body"

	http POST "$API/messages/$token" -u "$SERVICE_AUTH" --form-string 'content=<p>Third</p>'
	assert_eq "POST also updates" "200" "$STATUS"
	assert_match "POST replaces the content" "^<p>Third</p>" "$(post_content "$id")"

	http POST "$API/messages/$token" -u "$SERVICE_AUTH" --form-string 'content='
	assert_eq "empty content clears" "200" "$STATUS"
	assert_eq "clearing content still keeps the link" "<a href=\"$url\">Digital copy of your adoption certificate</a>" "$(post_content "$id")"

	http PATCH "$API/messages/$token" -u "$SERVICE_AUTH" -H 'Content-Type: application/json' -d '{}'
	assert_eq "update with nothing to change is 400" "400" "$STATUS"
	http PATCH "$API/messages/$token" -u "$SERVICE_AUTH" -H 'Content-Type: application/json' -d '{"name":"  "}'
	assert_eq "blank name is 400" "400" "$STATUS"
	assert_eq "token never changes" "$token" "$(wp_cli post meta get "$id" _donor_token)"

	load_legacy_fixtures
	rerun_upgrade
	http GET "$API/messages/${L_TOKEN[single]}" -u "$SERVICE_AUTH"
	assert_eq "legacy message reports its certificate" "${L_URL[single]}" "$(json_field pdf_url)"
	http GET "$API/messages/${L_TOKEN[double]}" -u "$SERVICE_AUTH"
	assert_eq "two-link legacy message reports no single certificate" "null" "$(json_field pdf_url)"

	http PATCH "$API/messages/${L_TOKEN[blank]}" -u "$SERVICE_AUTH" -H 'Content-Type: application/json' -d '{"content":"<p>Note</p>"}'
	body="$(post_content "${L_POST[blank]}")"
	assert_match "legacy link keeps its attributes" "^<p>Note</p>.*<a href=\"${L_URL[blank]}\" target=\"_blank\" rel=\"noopener\">Digital copy" "$body"

	http PATCH "$API/messages/${L_TOKEN[double]}" -u "$SERVICE_AUTH" -H 'Content-Type: application/json' -d '{"content":"<p>Note</p>"}'
	body="$(post_content "${L_POST[double]}")"
	assert_match "first legacy link survives" "${L_URL[double]}" "$body"
	assert_match "second legacy link survives" "${L_URL2[double]}" "$body"
}

t_reissue() {
	echo "reissue"
	api_users
	local id token page old old_att new new_att second body pdf2="$WORK/second.pdf" before
	make_pdf "$pdf2" 16
	create_message "Itest Reissue" "$(next_ref)"
	id="$(json_field id)"; token="$(json_field token)"; page="$(json_field page_url)"; old="$(json_field pdf_url)"
	old_att="$(wp_cli post meta get "$id" _donor_pdf_attachment_id)"

	http POST "$API/messages/$token/pdf" -u "$SERVICE_AUTH" -F "pdf=@$pdf2"
	assert_eq "reissue returns 200" "200" "$STATUS"
	new="$(json_field pdf_url)"
	assert_eq "reissue keeps the token" "$token" "$(json_field token)"
	assert_eq "reissue keeps the Donor Link" "$page" "$(json_field page_url)"
	assert_match "first reissue is revision 2" "/itest-Adoption-Certificate-$token-r2\.pdf$" "$new"

	body="$(post_content "$id")"
	assert_match "body links the new certificate" "<a href=\"$new\">Digital copy" "$body"
	assert_no_match "body no longer links the old one" "$(basename "$old")" "$body"

	http GET "$old"
	assert_eq "old certificate URL still works" "200" "$STATUS"
	assert_eq "old URL still serves the old file" "$(sha1sum < "$FIXTURE_PDF")" "$(sha1sum < "$WORK/body")"
	http GET "$new"
	assert_eq "new URL serves the new file" "$(sha1sum < "$pdf2")" "$(sha1sum < "$WORK/body")"

	new_att="$(wp_cli post meta get "$id" _donor_pdf_attachment_id)"
	assert_ne "a new attachment is tracked" "$old_att" "$new_att"
	assert_eq "old attachment stays private and flagged" "private 1" "$(att_state "$old_att")"
	assert_eq "new attachment is private and flagged" "private 1" "$(att_state "$new_att")"

	http POST "$API/messages/$token/pdf" -u "$SERVICE_AUTH" -F "pdf=@$FIXTURE_PDF" -F "filename_base=itest-Renamed"
	second="$(json_field pdf_url)"
	assert_match "next reissue is revision 3 with the new base" "/itest-Renamed-$token-r3\.pdf$" "$second"
	assert_eq "revision is tracked" "3" "$(wp_cli post meta get "$id" _donor_pdf_revision)"

	before="$(post_content "$id")"
	printf 'not a pdf\n' > "$WORK/bad.pdf"
	http POST "$API/messages/$token/pdf" -u "$SERVICE_AUTH" -F "pdf=@$WORK/bad.pdf;type=application/pdf"
	assert_eq "invalid reissue is refused" "400" "$STATUS"
	assert_eq "invalid reissue changes nothing" "$before" "$(post_content "$id")"

	http POST "$API/messages/$token/pdf" -u "$SERVICE_AUTH"
	assert_eq "reissue without a PDF is refused" "400" "$STATUS"

	wp_php "$token" <<'PHP' >/dev/null
<?php
touch(wp_upload_dir()['path'] . "/itest-Renamed-{$args[0]}-r4.pdf");
PHP
	http POST "$API/messages/$token/pdf" -u "$SERVICE_AUTH" -F "pdf=@$FIXTURE_PDF"
	assert_eq "a taken filename fails rather than gaining a suffix" "409" "$STATUS"
	assert_eq "a taken filename changes nothing" "$before" "$(post_content "$id")"
	assert_eq "a taken filename does not advance the revision" "3" "$(wp_cli post meta get "$id" _donor_pdf_revision)"
	wp_php "$token" <<'PHP' >/dev/null
<?php
unlink(wp_upload_dir()['path'] . "/itest-Renamed-{$args[0]}-r4.pdf");
PHP

	load_legacy_fixtures
	rerun_upgrade
	http POST "$API/messages/${L_TOKEN[single]}/pdf" -u "$SERVICE_AUTH" -F "pdf=@$pdf2"
	assert_eq "legacy message can be reissued" "200" "$STATUS"
	new="$(json_field pdf_url)"
	assert_match "legacy reissue derives its base and is revision 2" "/itest-Adoption-Certificate-${L_TOKEN[single]}-r2\.pdf$" "$new"
	assert_eq "legacy reissue swaps the link" "<a href=\"$new\">Digital copy of your adoption certificate</a>" "$(post_content "${L_POST[single]}")"
	http GET "${L_URL[single]}"
	assert_eq "legacy certificate URL still works" "200" "$STATUS"

	http POST "$API/messages/${L_TOKEN[blank]}/pdf" -u "$SERVICE_AUTH" -F "pdf=@$pdf2"
	assert_match "swap keeps link attributes" "<a href=\"$(json_field pdf_url)\" target=\"_blank\" rel=\"noopener\">" "$(post_content "${L_POST[blank]}")"

	local fp
	fp="$(fingerprint "${L_ATT[double]}" "${L_POST[double]}")"
	http POST "$API/messages/${L_TOKEN[double]}/pdf" -u "$SERVICE_AUTH" -F "pdf=@$pdf2"
	assert_eq "two-link legacy message is a conflict" "409" "$STATUS"
	assert_eq "conflict changes nothing" "$fp" "$(fingerprint "${L_ATT[double]}" "${L_POST[double]}")"

	http POST "$API/messages/${L_TOKEN[none]}/pdf" -u "$SERVICE_AUTH" -F "pdf=@$pdf2" -F "filename_base=itest-Added"
	assert_eq "message with no certificate can gain one" "200" "$STATUS"
	new="$(json_field pdf_url)"
	assert_match "a first certificate has no revision suffix" "/itest-Added-${L_TOKEN[none]}\.pdf$" "$new"
	assert_match "the standard link is appended" "^Thank you for your donation!.*<a href=\"$new\">Digital copy of your adoption certificate</a>$" "$(post_content "${L_POST[none]}")"
}

t_admin_uploads() {
	echo "admin uploads"
	local password jar="$WORK/cookies" post token nonce pdf="$WORK/upload.pdf" png="$WORK/photo.png" att
	password="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
	wp_cli user create itest_admin_editor itest_admin_editor@example.invalid --role=editor --user_pass="$password" --porcelain >/dev/null
	curl -gs -o /dev/null -c "$jar" -b 'wordpress_test_cookie=WP%20Cookie%20check' \
		--data-urlencode 'log=itest_admin_editor' --data-urlencode "pwd=$password" \
		-d 'wp-submit=Log+In&testcookie=1' "$WP_URL/wp-login.php"

	post="$(wp_cli post create --post_type=donor_message --post_status=publish --post_title='Itest Admin' --porcelain)"
	token="$(wp_cli post meta get "$post" _donor_token)"
	http GET "$WP_URL/wp-admin/post.php?post=$post&action=edit" -b "$jar"
	assert_eq "Editor can open the Donor Message" "200" "$STATUS"
	nonce="$(printf '%s' "$BODY" | sed -nE 's/.*"upload-attachment","_wpnonce":"([0-9a-f]+)".*/\1/p' | head -n 1)"
	assert_match "upload nonce is present" "^[0-9a-f]{10}$" "$nonce"

	make_pdf "$pdf"
	printf 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==' | base64 -d > "$png"

	upload() { # post-id (empty for the Media Library) file client-name
		http POST "$WP_URL/wp-admin/async-upload.php" -b "$jar" -F action=upload-attachment -F "_wpnonce=$nonce" \
			${1:+-F "post_id=$1"} -F "async-upload=@$2;filename=$3"
		att="$(printf '%s' "$BODY" | sed -nE 's/.*"data":\{"id":([0-9]+).*/\1/p')"
	}
	uploaded_name() { wp_php "$1" <<'PHP'
<?php
echo basename(get_attached_file((int) $args[0]));
PHP
	}

	# The browser only sends the post ID the page gives the media uploader,
	# so these take the ID from there, as the Add Media button does.
	media_post_id() { printf '%s' "$BODY" | sed -nE 's/.*media\.model\.settings\.post = \{"id":([0-9]+).*/\1/p' | head -n 1; }
	assert_eq "edit screen gives the media uploader its message" "$post" "$(media_post_id)"

	local new_post new_token draft
	http GET "$WP_URL/wp-admin/post-new.php?post_type=donor_message" -b "$jar"
	draft="$(printf '%s' "$BODY" | sed -nE "s/.*name='post_ID' value='([0-9]+)'.*/\1/p" | head -n 1)"
	new_post="$(media_post_id)"
	assert_eq "Add New screen gives the media uploader its message" "$draft" "$new_post"
	new_token="$(wp_cli post meta get "$draft" _donor_token)"
	upload "$new_post" "$pdf" "itest-new-message.pdf"
	assert_eq "Add Media on a new message adds the token" "itest-new-message-$new_token.pdf" "$(uploaded_name "$att")"
	assert_eq "Add Media on a new message makes it private" "private 1" "$(att_state "$att")"
	wp_cli post delete "$draft" --force >/dev/null

	upload "$post" "$pdf" "itest My File.pdf"
	assert_match "PDF upload succeeds" '"success":true' "$BODY"
	assert_eq "token is added to the filename" "itest-My-File-$token.pdf" "$(uploaded_name "$att")"
	assert_eq "upload becomes private and flagged" "private 1" "$(att_state "$att")"
	assert_eq "upload generates no previews" "0" "$(wp_php "$att" <<'PHP'
<?php
echo count(wp_get_attachment_metadata((int) $args[0])['sizes'] ?? []);
PHP
)"
	http GET "$WP_URL/wp-json/wp/v2/media/$att"
	assert_denied "uploaded certificate is hidden from anonymous users" "$STATUS"

	upload "$post" "$pdf" "itest-named-$token.pdf"
	assert_eq "a filename already holding the token is not doubled" "itest-named-$token.pdf" "$(uploaded_name "$att")"

	upload "$post" "$pdf" "itest-mid-$token-extra.pdf"
	assert_eq "a token anywhere in the filename leaves it as it is" "itest-mid-$token-extra.pdf" "$(uploaded_name "$att")"
	assert_eq "a filename already holding the token still becomes private" "private 1" "$(att_state "$att")"

	upload "$post" "$pdf" "itest My File.pdf"
	assert_match "a taken filename is refused" '"success":false' "$BODY"

	printf 'not a pdf\n' > "$WORK/fake.pdf"
	upload "$post" "$WORK/fake.pdf" "itest-fake.pdf"
	assert_match "fake PDF is refused" '"success":false' "$BODY"

	upload "$post" "$png" "itest-photo.png"
	assert_match "image upload to a message still works" '"success":true' "$BODY"
	assert_no_match "image keeps its own name" "$token" "$(uploaded_name "$att")"
	assert_eq "image is not treated as a certificate" "inherit unflagged" "$(att_state "$att")"

	local dated
	dated="$(wp_cli post create --post_type=donor_message --post_status=publish --post_title='Itest Dated' --post_date='2020-03-15 12:00:00' --porcelain)"
	upload "$dated" "$pdf" "itest-dated.pdf"
	assert_match "upload to an older message succeeds" '"success":true' "$BODY"
	upload "$dated" "$pdf" "itest-dated.pdf"
	assert_match "a taken filename in an older message's folder is refused" '"success":false' "$BODY"

	upload "" "$pdf" "itest-library.pdf"
	assert_match "Media Library PDF upload still works" '"success":true' "$BODY"
	assert_eq "Media Library PDF keeps its name" "itest-library.pdf" "$(uploaded_name "$att")"
	assert_eq "Media Library PDF is not a certificate" "inherit unflagged" "$(att_state "$att")"

	media_list() { http GET "$WP_URL/wp-admin/upload.php?mode=list&s=$1" -b "$jar"; }
	media_grid() { http POST "$WP_URL/wp-admin/admin-ajax.php" -b "$jar" -d action=query-attachments -d "query[s]=$1" ${2:+-d "post_id=$2"}; }

	media_list "$token"
	assert_no_match "Media Library list hides certificates by default" "itest-My-File" "$BODY"
	local toggle
	toggle="$(printf '%s' "$BODY" | sed -nE 's/.*href="([^"]*donor_certificates=show[^"]*)".*/\1/p' | sed -E 's/&(amp|#038);/\&/g' | head -n 1)"
	assert_match "Media Library offers a way to show them" "donor_certificates=show" "$toggle"
	media_grid "$token"
	assert_no_match "Media Library grid hides certificates by default" "itest-My-File" "$BODY"
	media_grid "$token" "$post"
	assert_match "the donor message's own media picker still shows them" "itest-My-File" "$BODY"
	media_grid "itest-library"
	assert_match "ordinary PDFs stay visible" "itest-library" "$BODY"

	http GET "$toggle" -b "$jar" -L
	assert_eq "show link works" "200" "$STATUS"
	media_list "$token"
	assert_match "list shows certificates once chosen" "itest-My-File" "$BODY"
	assert_match "and offers a way to hide them again" "donor_certificates=hide" "$BODY"
	media_grid "$token"
	assert_match "grid shows certificates once chosen" "itest-My-File" "$BODY"

	http GET "$WP_URL/wp-admin/upload.php?donor_certificates=hide" -b "$jar" -L
	media_list "$token"
	assert_match "the choice cannot be changed without a valid nonce" "itest-My-File" "$BODY"
}

t_changed_links() {
	echo "links changed outside the API"
	api_users
	load_legacy_fixtures
	rerun_upgrade
	local id="${L_POST[single]}" token="${L_TOKEN[single]}" linked="${L_URL[blank]}" body new
	wp_cli post update "$id" --post_content="<a href=\"$linked\">Digital copy of your adoption certificate</a>" >/dev/null

	http GET "$API/messages/$token" -u "$SERVICE_AUTH"
	assert_eq "fetch reports the link actually on the page" "$linked" "$(json_field pdf_url)"

	http PATCH "$API/messages/$token" -u "$SERVICE_AUTH" -H 'Content-Type: application/json' -d '{"content":"<p>Note</p>"}'
	assert_match "PATCH keeps a link that replaced the tracked one" "$linked" "$(post_content "$id")"

	http POST "$API/messages/$token/pdf" -u "$SERVICE_AUTH" -F "pdf=@$FIXTURE_PDF" -F "filename_base=itest-Repointed"
	assert_eq "reissue succeeds on a changed link" "200" "$STATUS"
	new="$(json_field pdf_url)"
	body="$(post_content "$id")"
	assert_eq "reissue swaps rather than appends" "1" "$(printf '%s' "$body" | grep -o '<a ' | wc -l | tr -d ' ')"
	assert_match "reissue links the new certificate" "$new" "$body"
	assert_no_match "reissue removes the replaced link" "$linked" "$body"

	local untracked
	untracked="$(wp_cli post create --post_type=donor_message --post_status=publish --post_title='Itest Untracked' --post_content="<a href=\"${L_URL[double]}\">Digital copy of your adoption certificate</a>" --porcelain)"
	http GET "$API/messages/$(wp_cli post meta get "$untracked" _donor_token)" -u "$SERVICE_AUTH"
	assert_eq "a message with one untracked link reports it" "${L_URL[double]}" "$(json_field pdf_url)"
}

# ---- main ------------------------------------------------------------------

guard_local_site
trap cleanup EXIT
sweep

ALL_SLICES="backfill anonymous_exposure token_requests api_auth api_create pdf_rejection idempotency read_update reissue changed_links admin_uploads"
for slice in ${*:-$ALL_SLICES}; do
	"t_$slice"
	sweep
	SERVICE_AUTH=""
	EDITOR_AUTH=""
done

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
