# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ISBF careers native integration", type: :request do
  fab!(:category)
  fab!(:other_category) { Fabricate(:category) }
  fab!(:member) { Fabricate(:user, active: true, approved: true, trust_level: 1, refresh_auto_groups: true) }
  fab!(:other_member) { Fabricate(:user, active: true, approved: true, trust_level: 1, refresh_auto_groups: true) }
  fab!(:admin)

  before do
    SiteSetting.isbf_careers_enabled = true
    SiteSetting.isbf_careers_publishing_enabled = true
    SiteSetting.isbf_careers_category_id = category.id
    SiteSetting.approve_post_count = 0
    SiteSetting.approve_unless_allowed_groups = Group::AUTO_GROUPS[:trust_level_0].to_s
    SiteSetting.approve_new_topics_unless_allowed_groups = Group::AUTO_GROUPS[:trust_level_0].to_s
    SiteSetting.skip_review_media_groups = Group::AUTO_GROUPS[:trust_level_0].to_s
    category.set_permissions(trust_level_0: :full, staff: :full)
    category.save!
  end

  def payload(extra = {})
    @submission_number = (@submission_number || 0) + 1
    {
      title: "Campus project team #{@submission_number}",
      raw: "We are looking for campus project teammates this semester.",
      category: category.id,
    }.merge(extra)
  end

  def submit(extra = {}, actor: member, **fields)
    sign_in(actor)
    post "/posts.json", params: payload(extra.merge(fields))
  end

  def created_post
    expect(response.status).to eq(200), response.body
    Post.find(response.parsed_body.fetch("id"))
  end

  def topic_ids
    expect(response.status).to eq(200), response.body
    response.parsed_body.fetch("topic_list").fetch("topics").map { |topic| topic.fetch("id") }
  end

  def update_careers_post(post_record, fields = {}, title: nil, **updates)
    params = { post: { raw: post_record.reload.raw }.merge(fields).merge(updates) }
    params[:title] = title unless title.nil?
    put "/posts/#{post_record.id}.json", params: params
  end

  def make_careers(home: :legacy, created_at: Time.zone.now)
    topic = Fabricate(:topic, category: category, user: member, created_at: created_at, bumped_at: created_at)
    Fabricate(:post, topic: topic, user: member)
    if home != :legacy
      topic.custom_fields[IsbfCareers::HOME_FIELD] = home
      topic.save_custom_fields
    end
    topic
  end

  it "preserves salary and native content through create, revision, body edits and clearing" do
    submit(isbf_careers_salary: "  面议 / 200元每天  ")
    first = created_post
    author_id = first.user_id
    original_time = first.created_at
    expect(first.topic.custom_fields[IsbfCareers::SALARY_FIELD]).to eq("面议 / 200元每天")
    expect(response.parsed_body["isbf_careers"]).to include("salary" => "面议 / 200元每天", "description" => first.raw)
    update_careers_post(first, isbf_careers_salary: "30k/月")
    expect(response.status).to eq(200), response.body
    revision = PostRevision.where(post_id: first.id).order(:number).last
    expect(revision.modifications[IsbfCareers::SALARY_FIELD]).to eq(["面议 / 200元每天", "30k/月"])
    update_careers_post(first, raw: "Updated campus internship job description.", isbf_careers_salary: nil)
    expect(response.status).to eq(200), response.body
    expect(first.topic.reload.custom_fields[IsbfCareers::SALARY_FIELD]).to eq("30k/月")
    expect(first.topic.custom_fields[IsbfCareers::DESCRIPTION_FIELD]).to eq("Updated campus internship job description.")
    update_careers_post(first, isbf_careers_salary: "")
    expect(response.status).to eq(200), response.body
    expect(first.topic.reload.custom_fields[IsbfCareers::SALARY_FIELD]).to be_nil
    expect(first.reload.user_id).to eq(author_id)
    expect(first.created_at).to eq(original_time)
  end

  ["薪" * 121, "line\nline", ["invalid"]].each do |salary|
    it "rejects invalid salary #{salary.inspect} on native create and edit" do
      expect do
        submit(isbf_careers_salary: salary)
        expect([400, 422]).to include(response.status), response.body
      end.not_to change(Topic, :count)
      submit
      first = created_post
      update_careers_post(first, isbf_careers_salary: salary)
      expect([400, 422]).to include(response.status), response.body
      expect(first.topic.reload.custom_fields[IsbfCareers::SALARY_FIELD]).to be_nil
    end
  end

  it "keeps career draft data in the native draft payload" do
    sign_in(member)
    data = { title: "Campus internship", reply: "Real position description", categoryId: category.id,
             isbf_careers_salary: "面议", isbf_careers_home: false }.to_json
    post "/drafts.json", params: { draft_key: "new_topic", sequence: 0, data: data }
    expect(response.status).to eq(200), response.body
    get "/drafts/new_topic.json"
    expect(response.status).to eq(200), response.body
    draft = response.parsed_body.fetch("draft")
    expect(JSON.parse(draft.is_a?(Hash) ? draft.fetch("data") : draft)).to include(
      "isbf_careers_salary" => "面议", "isbf_careers_home" => false,
    )
  end

  it "creates one native topic with a home opt-out and no forced moderation" do
    expect { submit }.to change(Topic.where(category_id: category.id), :count).by(1)
    first = created_post
    expect(first.is_first_post?).to eq(true)
    expect(first.topic.custom_fields[IsbfCareers::HOME_FIELD]).to eq(false)
    expect(response.parsed_body["isbf_careers"]).to include("show_on_home" => false)
    expect(ReviewableQueuedPost.pending.where(category_id: category.id)).to be_empty
    get "/latest.json"
    expect(topic_ids).not_to include(first.topic_id)
  end

  it "accepts an explicit opt-in and native optional uploads" do
    upload = Fabricate(:upload, user: member)
    submit(isbf_careers_home: "true", raw: "Campus project details and our reference photo.\n\n![Campus photo](#{upload.short_url})")
    first = created_post
    expect(first.topic.custom_fields[IsbfCareers::HOME_FIELD]).to eq(true)
    expect(first.raw).to include(upload.short_url)
    get "/latest.json"
    expect(topic_ids).to include(first.topic_id)
  end

  [{ title: "" }, { title: "  " }, { title: "[isbf-untitled:abc]" }, { raw: "" }, { raw: "  " },
   { isbf_careers_home: "yes" }, { category: 0, isbf_careers_home: "true" }].each_with_index do |extra, index|
    it "rejects invalid submission #{index + 1} without a topic or reviewable" do
      expect do
        expect do
          submit(extra)
          expect([403, 422]).to include(response.status), response.body
        end.not_to change(ReviewableQueuedPost, :count)
      end.not_to change(Topic, :count)
    end
  end

  [true, "true"].each do |flag|
    it "rejects anonymous #{flag.inspect} on direct native first-post and reply requests" do
      topic = make_careers
      sign_in(member)
      [payload(isbf_anonymous: flag), { topic_id: topic.id, raw: "I would like to join the team.", isbf_anonymous: flag }].each do |params|
        expect do
          expect do
            post "/posts.json", params: params
            expect([403, 422]).to include(response.status), response.body
          end.not_to change(ReviewableQueuedPost, :count)
        end.not_to change(Post, :count)
      end
    end
  end

  it "keeps named replies and other categories on the native path" do
    submit(category: other_category.id)
    ordinary = created_post
    expect(ordinary.topic.custom_fields[IsbfCareers::HOME_FIELD]).to be_nil
    submit
    first = created_post
    post "/posts.json", params: { topic_id: first.topic_id, raw: "I would like to join this campus project." }
    reply = created_post
    expect(reply.post_number).to eq(2)
    expect(response.parsed_body).not_to have_key("isbf_careers")
    expect(first.topic.reload.custom_fields[IsbfCareers::HOME_FIELD]).to eq(false)
  end

  it "rejects careers metadata on other categories and replies" do
    submit(category: other_category.id, isbf_careers_salary: "面议")
    expect(response.status).to eq(422), response.body
    submit(category: other_category.id, isbf_careers_home: "true")
    expect(response.status).to eq(422), response.body
    submit
    first = created_post
    post "/posts.json", params: { topic_id: first.topic_id, raw: "I would like to join this campus project.", isbf_careers_home: "true" }
    expect(response.status).to eq(422), response.body
    post "/posts.json", params: { topic_id: first.topic_id, raw: "Interested in this position.", isbf_careers_salary: "面议" }
    expect(response.status).to eq(422), response.body
    update_careers_post(first, isbf_careers_home: "yes")
    expect(response.status).to eq(400), response.body
    expect(response.parsed_body["error_type"]).to eq("invalid_parameters")
    expect(first.topic.reload.custom_fields[IsbfCareers::HOME_FIELD]).to eq(false)
  end

  it "revises home visibility through PostRevisor, records the change, and preserves it on body edits" do
    submit
    first = created_post
    update_careers_post(first, isbf_careers_home: "true")
    expect(response.status).to eq(200), response.body
    expect(first.topic.reload.custom_fields[IsbfCareers::HOME_FIELD]).to eq(true)
    revision = PostRevision.where(post_id: first.id).order(:number).last
    expect(revision.modifications[IsbfCareers::HOME_FIELD]).to eq([false, true])
    update_careers_post(first, raw: "Updated project details: we meet on campus every Friday.")
    expect(response.status).to eq(200), response.body
    expect(first.topic.reload.custom_fields[IsbfCareers::HOME_FIELD]).to eq(true)
    update_careers_post(first, isbf_careers_home: "false")
    expect(response.status).to eq(200), response.body
    expect(first.topic.reload.custom_fields[IsbfCareers::HOME_FIELD]).to eq(false)
  end

  it "preserves missing legacy flags on ordinary edits and allows explicit opt-out" do
    legacy = make_careers
    sign_in(member)
    update_careers_post(legacy.first_post, raw: "Updated legacy careers details for this semester.")
    expect(response.status).to eq(200), response.body
    expect(legacy.reload.custom_fields).not_to have_key(IsbfCareers::HOME_FIELD)
    get "/latest.json"
    expect(topic_ids).to include(legacy.id)
    update_careers_post(legacy.first_post, isbf_careers_home: "false")
    expect(response.status).to eq(200), response.body
    expect(legacy.reload.custom_fields[IsbfCareers::HOME_FIELD]).to eq(false)
    get "/latest.json"
    expect(topic_ids).not_to include(legacy.id)
  end

  it "rejects empty title, empty body, and anonymous conversion during native edit" do
    submit
    first = created_post
    [{ raw: "" }, { isbf_anonymous: true }, { isbf_anonymous: "true" }].each do |fields|
      update_careers_post(first, fields)
      expect(response.status).to eq(400), response.body
      expect(response.parsed_body["error_type"]).to eq("invalid_parameters")
    end
    ["", "[isbf-untitled:abc]"].each do |title|
      update_careers_post(first, title: title)
      expect(response.status).to eq(400), response.body
      expect(response.parsed_body["error_type"]).to eq("invalid_parameters")
    end
    reply = Fabricate(:post, topic: first.topic, user: member)
    update_careers_post(reply, isbf_anonymous: "true")
    expect(response.status).to eq(400), response.body
    expect(response.parsed_body["error_type"]).to eq("invalid_parameters")
    expect(first.reload.user_id).to eq(member.id)
  end

  it "retains native edit permissions for authors, other users, and staff" do
    submit
    first = created_post
    sign_in(other_member)
    update_careers_post(first, isbf_careers_home: "true")
    expect(response.status).to eq(403), response.body
    expect(first.topic.reload.custom_fields[IsbfCareers::HOME_FIELD]).to eq(false)
    sign_in(admin)
    update_careers_post(first, isbf_careers_home: "true")
    expect(response.status).to eq(200), response.body
    expect(first.topic.reload.custom_fields[IsbfCareers::HOME_FIELD]).to eq(true)
  end

  it "requires login and respects category creation permissions and the publishing switch" do
    post "/posts.json", params: payload
    expect(response.status).to eq(403), response.body
    category.set_permissions(trust_level_0: :readonly, staff: :full)
    category.save!
    submit
    expect([403, 422]).to include(response.status), response.body
    submit({}, actor: admin)
    created_post
    SiteSetting.isbf_careers_publishing_enabled = false
    submit({}, actor: admin)
    expect(response.status).to eq(422), response.body
  end

  it "serializes actual configuration and matching first-post metadata through native serializers" do
    submit(isbf_careers_home: "true")
    first = created_post
    get "/site.json"
    expect(response.status).to eq(200), response.body
    expect(response.parsed_body["isbf_careers"]).to include(
      "category_id" => category.id, "enabled" => true, "publishing_enabled" => true, "version" => 1, "salary_max_length" => 120,
    )
    get "/t/#{first.topic_id}.json"
    expect(response.status).to eq(200), response.body
    expect(response.parsed_body["isbf_careers"]).to include("show_on_home" => true)
    expect(response.parsed_body.dig("post_stream", "posts").first["isbf_careers"]).to include("show_on_home" => true)
    get "/filter.json", params: { q: "isbf-careers:all order:created" }
    expect(response.parsed_body.dig("topic_list", "topics").first["isbf_careers"]).to include("show_on_home" => true)
  end

  context "with the direct HTML entry route" do
    it "uses native login for a guest's direct page request" do
      get "/isbf/careers", headers: { "HTTP_ACCEPT" => "text/html" }
      expect(response.status).to eq(404), response.body
    end

    it "boots the native application for a member, including when new publishing is disabled" do
      sign_in(member)
      get "/isbf/careers", headers: { "HTTP_ACCEPT" => "text/html" }
      expect(response.status).to eq(200), response.body
      SiteSetting.isbf_careers_publishing_enabled = false
      get "/isbf/careers", headers: { "HTTP_ACCEPT" => "text/html" }
      expect(response.status).to eq(200), response.body
      topic = make_careers
      post "/posts.json", params: { topic_id: topic.id, raw: "Named replies remain available while publishing is paused." }
      reply = created_post
      update_careers_post(reply, raw: "Named edits also remain available while publishing is paused.")
      expect(response.status).to eq(200), response.body
    end

    it "denies a category the member cannot see and admits staff through native permissions" do
      category.set_permissions(staff: :full)
      category.save!
      sign_in(member)
      get "/isbf/careers", headers: { "HTTP_ACCEPT" => "text/html" }
      expect(response.status).to eq(404), response.body
      sign_in(admin)
      get "/isbf/careers", headers: { "HTTP_ACCEPT" => "text/html" }
      expect(response.status).to eq(200), response.body
    end

    it "returns native not-found responses for an unconfigured or disabled integration" do
      sign_in(member)
      SiteSetting.isbf_careers_category_id = 0
      get "/isbf/careers", headers: { "HTTP_ACCEPT" => "text/html" }
      expect(response.status).to eq(404), response.body
      SiteSetting.isbf_careers_category_id = category.id
      SiteSetting.isbf_careers_enabled = false
      get "/isbf/careers", headers: { "HTTP_ACCEPT" => "text/html" }
      expect(response.status).to eq(404), response.body
    end
  end

  context "with native approval required" do
    before { SiteSetting.approve_post_count = 100 }

    def queue_careers(extra = {})
      expect do
        submit(extra)
        expect(response.status).to eq(200), response.body
      end.not_to change(Topic, :count)
      ReviewableQueuedPost.pending.where(category_id: category.id).order(:id).last.tap do |reviewable|
        expect(reviewable).to be_present
      end
    end

    [nil, false, "false", true, "true"].each do |flag|
      it "preserves home choice #{flag.inspect} through the native queue and approval" do
        reviewable = queue_careers({ isbf_careers_salary: "  面议  " }.merge(flag.nil? ? {} : { isbf_careers_home: flag }))
        expect(reviewable.payload[IsbfCareers::SALARY_FIELD]).to eq("面议")
        expected = [true, "true"].include?(flag)
        expect(reviewable.payload[IsbfCareers::HOME_FIELD]).to eq(expected.to_s)
        approval = reviewable.perform(admin, :approve_post)
        expect(approval.success?).to eq(true), approval.errors.inspect
        expect(approval.created_post.topic.reload.custom_fields[IsbfCareers::HOME_FIELD]).to eq(expected)
        expect(approval.created_post.topic.custom_fields[IsbfCareers::SALARY_FIELD]).to eq("面议")
        expect(approval.created_post.topic.custom_fields[IsbfCareers::DESCRIPTION_FIELD]).to eq(
          "We are looking for campus project teammates this semester.",
        )
        expect(IsbfCareers.metadata(approval.created_post.topic)[:description]).to be_present
      end
    end

    it "rejects through native review without publishing and retains the home choice" do
      reviewable = queue_careers(isbf_careers_home: "true")
      expect { expect(reviewable.perform(admin, :reject_post).success?).to eq(true) }.not_to change(Topic, :count)
      expect(reviewable.reload).to be_rejected
      expect(reviewable.payload[IsbfCareers::HOME_FIELD]).to eq("true")
    end

    [{ "isbf_anonymous" => "true" }, { "title" => "[isbf-untitled:tampered]" }, { "raw" => "" },
     { IsbfCareers::HOME_FIELD => "yes" }, { IsbfCareers::SALARY_FIELD => "薪" * 121 }].each_with_index do |extra, index|
      it "revalidates modified queue payload #{index + 1} before skipped-validation approval" do
        reviewable = queue_careers
        reviewable.update!(payload: reviewable.payload.merge(extra))
        expect do
          begin
            expect(reviewable.perform(admin, :approve_post).success?).to eq(false)
          rescue Discourse::InvalidAccess, Discourse::InvalidParameters
            # Native review may surface a rejected payload as an exception.
          end
        end.not_to change(Topic, :count)
        expect(reviewable.reload).to be_pending
      end
    end
  end

  context "with native topic lists" do
    before { sign_in(member) }

    it "filters home opt-outs before pagination, keeping legacy and explicit opt-ins" do
      opted_out = make_careers(home: false, created_at: 1.day.ago)
      opted_in = make_careers(home: true, created_at: 2.days.ago)
      legacy = make_careers(created_at: 3.days.ago)
      stub_const(TopicQuery, "DEFAULT_PER_PAGE_COUNT", 1) do
        get "/latest.json"
        expect(topic_ids).to eq([opted_in.id])
        get "/latest.json", params: { page: 1 }
        expect(topic_ids).to eq([legacy.id])
      end
      get "/c/#{category.slug}/#{category.id}/l/latest.json"
      expect(topic_ids).to include(opted_out.id, opted_in.id, legacy.id)
      get "/latest.json", params: { category: category.id }
      expect(topic_ids).to include(opted_out.id, opted_in.id, legacy.id)
      get "/latest.json", params: { q: "category:#{category.slug}" }
      expect(topic_ids).to include(opted_out.id, opted_in.id, legacy.id)
    end

    it "uses native filter pagination and creation order regardless of home visibility" do
      legacy = make_careers(created_at: 3.days.ago)
      opted_in = make_careers(home: true, created_at: 2.days.ago)
      opted_out = make_careers(home: false, created_at: 1.day.ago)
      stub_const(TopicQuery, "DEFAULT_PER_PAGE_COUNT", 1) do
        get "/filter.json", params: { q: "isbf-careers:all order:created" }
        expect(topic_ids).to eq([opted_out.id])
        get "/filter.json", params: { q: "isbf-careers:all order:created", page: 1 }
        expect(topic_ids).to eq([opted_in.id])
        get "/filter.json", params: { q: "isbf-careers:all order:created", page: 2 }
        expect(topic_ids).to eq([legacy.id])
      end
    end

    it "excludes hidden, deleted, user-deleted and unlisted first posts from the workbench filter" do
      visible = make_careers(home: false)
      excluded = [:hidden, :user_deleted, :deleted_post, :deleted_topic, :unlisted].map do |state|
        topic = make_careers
        case state
        when :hidden then topic.first_post.update!(hidden: true)
        when :user_deleted then topic.first_post.update!(user_deleted: true)
        when :deleted_post then topic.first_post.trash!
        when :deleted_topic then topic.trash!
        when :unlisted then topic.update!(visible: false)
        end
        topic.id
      end
      get "/filter.json", params: { q: "isbf-careers:all order:created" }
      expect(topic_ids).to eq([visible.id])
      expect(topic_ids & excluded).to be_empty
    end

    it "does not show the native category description as a careers post" do
      visible = make_careers
      description = Fabricate(:post, topic: Fabricate(:topic, category: category), user: Discourse.system_user)
      category.update!(topic_id: description.topic_id)
      SiteSetting.show_category_definitions_in_topic_lists = true
      get "/filter.json", params: { q: "isbf-careers:all order:created" }
      expect(topic_ids).to eq([visible.id])
    end

    it "respects native category access and requires login for the workbench filter" do
      topic = make_careers
      category.set_permissions(staff: :full)
      category.save!
      get "/filter.json", params: { q: "isbf-careers:all order:created" }
      expect(topic_ids).to be_empty
      sign_in(admin)
      get "/filter.json", params: { q: "isbf-careers:all order:created" }
      expect(topic_ids).to include(topic.id)
      category.set_permissions(everyone: :full, staff: :full)
      category.save!
      sign_out
      reset!
      expect(cookies[Auth::DefaultCurrentUserProvider::TOKEN_COOKIE].nil?).to eq(true)
      get "/filter.json", params: { q: "isbf-careers:all order:created" }
      expect(topic_ids).to be_empty
    end

    it "preserves search, category, tag and author activity for a home opt-out" do
      UserActionManager.enable
      first = nil
      SearchIndexer.with_indexing do
        submit(title: "Careers unique searchable robotics internship")
        first = created_post
        SearchIndexer.index(first.topic, force: true)
        SearchIndexer.index(first, force: true)
      end
      get "/search.json", params: { q: "searchable robotics" }
      expect(response.status).to eq(200), response.body
      expect(response.parsed_body.fetch("topics").map { |topic| topic.fetch("id") }).to include(first.topic_id)
      get "/user_actions.json", params: { username: member.username, filter: UserAction::NEW_TOPIC }
      expect(response.status).to eq(200), response.body
      expect(response.parsed_body.fetch("user_actions").map { |action| action.fetch("topic_id") }).to include(first.topic_id)
      get "/filter.json", params: { q: "category:#{category.slug} order:created" }
      expect(topic_ids).to include(first.topic_id)
      SiteSetting.tagging_enabled = true
      tag = Fabricate(:tag)
      first.topic.tags << tag
      get "/tag/#{tag.id}.json"
      expect(topic_ids).to include(first.topic_id)
    end

    it "combines home exclusions with the companion marketplace query when installed" do
      skip "ISBF Marketplace is tested on the deployment integration environment" unless defined?(IsbfMarketplace)
      marketplace_category = Fabricate(:category)
      SiteSetting.isbf_marketplace_enabled = true
      SiteSetting.isbf_marketplace_category_id = marketplace_category.id
      product = Fabricate(:post, topic: Fabricate(:topic, category: marketplace_category)).topic
      product.custom_fields[IsbfMarketplace::PRICE_FIELD] = 0
      product.custom_fields[IsbfMarketplace::HOME_FIELD] = false
      product.save_custom_fields
      careers = make_careers(home: false)
      visible = make_careers(home: true)
      get "/latest.json"
      expect(topic_ids).to include(visible.id)
      expect(topic_ids).not_to include(product.id, careers.id)
    end
  end
end