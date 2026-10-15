# ISBF Careers

Independent Discourse plugin for native 求职实习 topics. Repository: https://github.com/ISBF-Lab/ISBF-Careers.

## Configuration

Set `isbf_careers_category_id` to an existing category ID, distinct from configured Marketplace, Teamup, Learning, Library and Official categories. Unavailable companion settings are ignored safely. `0` means unconfigured. The plugin does not create categories or change permissions. `isbf_careers_enabled` enables the integration; `isbf_careers_publishing_enabled` controls new topics and moves into the category. Replies and edits retain native permissions.

## Native contract

- `POST /posts.json` requires a real title and body. Internal `[isbf-untitled:…]` titles and anonymous first posts/replies are rejected, including native shadow identities and per-post anonymous markers.
- Optional `isbf_careers_salary` accepts free text of at most 120 Unicode characters after trimming whitespace. Blank becomes null; non-string, invalid encoding and control characters are rejected.
- `isbf_careers_home` accepts booleans or `"true"` / `"false"`. New topics always persist false unless opted in. Legacy topics lacking the field retain home visibility.
- First-post edits use native `PUT /posts/:id.json` and PostRevisor. Empty salary clears it; null or absent salary/home means unspecified. Salary and home changes are recorded in native revisions; body edits update the cached plain excerpt without replacing native raw/cooked content, author, timestamps, attachments or revisions.
- Native topic-list/topic-view/first-post serializers expose `isbf_careers: {salary, show_on_home, description}`. Description is a plain excerpt of cooked content, capped at 280 characters. The cached field is server generated and never a permitted client parameter.
- Site configuration exposes `isbf_careers: {category_id, version: 1, enabled, publishing_enabled, salary_max_length: 120}` when configured.
- The theme uses `/filter.json?q=isbf-careers:all%20order:created`, retaining native ordering and pagination. The filter requires login and native category access, and excludes private, deleted, unlisted, category-description topics and hidden/deleted first posts.
- Unfiltered `/latest.json` excludes explicit home opt-outs in SQL before pagination. Category, tag, search and profile lists retain native behavior. Other plugins can compose their home filters.
- Native Composer, drafts, optional uploads, NewPostManager review decisions and ReviewableQueuedPost approval remain in use. Queue payloads retain salary and home fields. Creation is revalidated at persistence so approval cannot bypass validation by skipping normal events.
- Moving a topic into the category requires native creation rights and named content throughout its first post and replies. Original posts remain native records.

No Core edits, tables, migrations, upload controllers, upload hooks or separate moderation queue are introduced.

## Validation

Focused specs cover normalization, native creation/edit/clearing, drafts, serializers, permissions, anonymous identities/category moves, optional native attachments, moderation payload tampering, home filtering before pagination and unaffected category/tag/search/profile visibility. Companion-plugin cases report skips when unavailable.

`.github/workflows/test.yml` uses the official `discourse/.github/.github/workflows/discourse-plugin.yml@main` backend workflow with fixed public upstream Core commit `2b7d4b0063543e910fd0cdc3d6c94d9347085f49`, matching the adjacent Teamup plugin. It does not copy private Core sources or use site credentials.

Run Ruby syntax with `find . -name '*.rb' -not -path './.git/*' -print0 | xargs -0 -n1 ruby -c`, and installer syntax with `bash -n deploy/install-plugin.sh`. Request and lib specs require the Discourse test harness; local static checks cannot establish runtime compatibility or browser behavior.

## Deployment and rollback

Prepare the reviewed merged commit at `/shared/isbf-careers-releases/<commit>/isbf-careers` inside the existing container. `deploy/install-plugin.sh <40-character-commit>` selects it using the `/var/www/discourse/plugins/isbf-careers` symlink and refuses to overwrite a normal directory. Release orchestration, rebuild/restart and category configuration belong to the coordinator.

To pause new publishing, set `isbf_careers_publishing_enabled` to false. Preserve the enabled plugin, category setting, topic fields and home filters so existing topics and home opt-outs remain effective. Restore the previous theme while retaining home-filter compatibility. This plugin introduces no schema or private upload storage to migrate.
