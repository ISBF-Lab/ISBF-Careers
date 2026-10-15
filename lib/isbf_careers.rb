# frozen_string_literal: true

module IsbfCareers
  SALARY_FIELD = "isbf_careers_salary"
  DESCRIPTION_FIELD = "isbf_careers_description"
  SALARY_MAX_LENGTH = 120
  FIELDS = [SALARY_FIELD, "isbf_careers_home"].freeze
  HOME_FIELD = "isbf_careers_home"
  ANONYMOUS_FIELD = "isbf_per_post_anonymous"

  def self.category_id
    id = SiteSetting.isbf_careers_category_id.to_i
    id if id.positive?
  end

  def self.enabled?
    SiteSetting.isbf_careers_enabled && category_id
  end

  def self.careers?(topic)
    enabled? && topic&.category_id == category_id && !topic.private_message?
  end

  def self.target?(options)
    return false unless enabled?
    if options[:topic_id].present?
      careers?(Topic.find_by(id: options[:topic_id]))
    else
      options[:category].to_i == category_id && options[:archetype] != Archetype.private_message
    end
  end

  def self.home_supplied?(options)
    !options[HOME_FIELD.to_sym].nil?
  end

  def self.supplied?(options)
    FIELDS.any? { |field| !options[field.to_sym].nil? }
  end

  def self.salary(value)
    return nil if value.nil?
    unless value.is_a?(String) && value.valid_encoding? && !value.match?(/[[:cntrl:]]/)
      raise Discourse::InvalidParameters.new(SALARY_FIELD)
    end
    text = value.gsub(/\A[[:space:]]+|[[:space:]]+\z/, "")
    raise Discourse::InvalidParameters.new(SALARY_FIELD) if text.length > SALARY_MAX_LENGTH
    text.presence
  end

  def self.description(cooked)
    Nokogiri::HTML.fragment(cooked.to_s).text.gsub(/[[:space:]]+/, " ").strip.truncate(280, omission: "")
  end

  def self.home_flag(value)
    return false if value.nil? || value == false || value == "false"
    return true if value == true || value == "true"
    raise Discourse::InvalidParameters.new(HOME_FIELD)
  end

  def self.show_on_home?(topic)
    value = topic.custom_fields[HOME_FIELD]
    value.nil? || value == true
  end

  def self.anonymous_identity?(user)
    user && (user.anonymous? || AnonymousUser.exists?(user_id: user.id))
  end

  def self.reject_anonymous!(user, options)
    requested = ActiveModel::Type::Boolean.new.cast(options[:isbf_anonymous])
    marked = options[:custom_fields]&.with_indifferent_access&.[](ANONYMOUS_FIELD)
    if requested || ActiveModel::Type::Boolean.new.cast(marked) || anonymous_identity?(user)
      raise Discourse::InvalidParameters.new(I18n.t("isbf_careers.anonymous_not_allowed"))
    end
  end

  def self.validate_content!(title, raw)
    if !title.is_a?(String) || !raw.is_a?(String) || title.strip.blank? || title.include?("[isbf-untitled:") || raw.strip.blank?
      raise Discourse::InvalidParameters.new(I18n.t("isbf_careers.invalid"))
    end
  end

  def self.validate_creation!(user, options, guardian: Guardian.new(user))
    return unless SiteSetting.isbf_careers_enabled
    targeted = target?(options)
    raise Discourse::InvalidParameters.new(HOME_FIELD) if supplied?(options) && !targeted
    return unless targeted

    raise Discourse::InvalidAccess unless user
    reject_anonymous!(user, options)
    if options[:topic_id].present?
      raise Discourse::InvalidParameters.new(HOME_FIELD) if supplied?(options)
      topic = Topic.find_by(id: options[:topic_id])
      raise Discourse::InvalidAccess unless guardian.can_create?(Post, topic)
      nil
    else
      category = Category.find_by(id: category_id)
      unless SiteSetting.isbf_careers_publishing_enabled && category && guardian.can_create?(Topic, category)
        raise Discourse::InvalidAccess
      end
      validate_content!(options[:title], options[:raw])
      salary(options[SALARY_FIELD.to_sym])
      home_flag(options[HOME_FIELD.to_sym])
    end
  end

  def self.validate_post_author!(post)
    return unless careers?(post.topic)
    reject_anonymous!(post.user, custom_fields: post.custom_fields)
  end

  def self.anonymous_content?(topic)
    posts = topic.posts
    marked = PostCustomField.where(name: ANONYMOUS_FIELD, value: "t").select(:post_id)
    shadows = AnonymousUser.select(:user_id)
    anonymous = posts.where(user_id: shadows).or(posts.where(id: marked))
    if defined?(IsbfAnonymous) && IsbfAnonymous.respond_to?(:pool_user_ids)
      anonymous = anonymous.or(posts.where(user_id: IsbfAnonymous.pool_user_ids))
    end
    anonymous.exists?
  end

  def self.validate_update!(editor, post, fields)
    return unless SiteSetting.isbf_careers_enabled
    target_category = fields[:category_id].nil? ? post.topic.category_id : fields[:category_id].to_i
    targeted = careers?(post.topic) || (post.is_first_post? && target_category == category_id)
    if supplied?(fields) && (!targeted || !post.is_first_post? || target_category != category_id)
      raise Discourse::InvalidParameters.new(HOME_FIELD)
    end
    return unless targeted

    raise Discourse::InvalidAccess unless Guardian.new(editor).can_edit_post?(post)
    reject_anonymous!(editor, fields)
    author = fields[:user_id].nil? ? post.user : User.find_by(id: fields[:user_id])
    reject_anonymous!(author, custom_fields: post.custom_fields)
    if post.is_first_post? && target_category == category_id
      unless careers?(post.topic)
        category = Category.find_by(id: category_id)
        unless SiteSetting.isbf_careers_publishing_enabled && category && Guardian.new(editor).can_create?(Topic, category)
          raise Discourse::InvalidAccess
        end
        if anonymous_content?(post.topic)
          raise Discourse::InvalidParameters.new(I18n.t("isbf_careers.anonymous_not_allowed"))
        end
      end
      validate_content!(fields.fetch(:title, post.topic.title), fields.fetch(:raw, post.raw))
      salary(fields[SALARY_FIELD]) unless fields[SALARY_FIELD].nil?
      home_flag(fields[HOME_FIELD]) if home_supplied?(fields)
    end
  end

  def self.metadata(topic)
    { salary: topic.custom_fields[SALARY_FIELD], show_on_home: show_on_home?(topic),
      description: topic.custom_fields[DESCRIPTION_FIELD].to_s } if careers?(topic)
  end

  def self.home_scope(topics)
    return topics unless enabled?
    topics.where(<<~SQL, category_id, HOME_FIELD)
      topics.category_id <> ? OR NOT EXISTS (
        SELECT 1 FROM topic_custom_fields AS careers_home
        WHERE careers_home.topic_id = topics.id AND careers_home.name = ?
          AND careers_home.value = 'f'
      )
    SQL
  end

  def self.filter(topics, values, guardian)
    return topics.none unless enabled? && guardian.user && values == ["all"]
    category = Category.find_by(id: category_id)
    return topics.none unless category && guardian.can_see_category?(category)

    topics.where(category_id: category_id, archetype: Archetype.default, visible: true, deleted_at: nil).where.not(id: category.topic_id).where(<<~SQL)
      EXISTS (SELECT 1 FROM posts AS careers_post
        WHERE careers_post.topic_id = topics.id AND careers_post.post_number = 1
          AND careers_post.deleted_at IS NULL AND NOT careers_post.user_deleted
          AND NOT careers_post.hidden)
    SQL
  end

  module PostCreation
    def valid?
      IsbfCareers.validate_creation!(@user, opts, guardian: guardian)
      super
    end

    private

    # Native approval skips normal validation events, so check at persistence too.
    def save_post
      home = IsbfCareers.validate_creation!(@user, opts, guardian: guardian)
      IsbfCareers.validate_post_author!(@post)
      result = super
      if @post.is_first_post? && IsbfCareers.careers?(@post.topic)
        @post.topic.custom_fields[HOME_FIELD] = home
        @post.topic.custom_fields[SALARY_FIELD] = IsbfCareers.salary(opts[SALARY_FIELD.to_sym])
        @post.topic.custom_fields[DESCRIPTION_FIELD] = IsbfCareers.description(@post.cooked)
        @post.topic.save_custom_fields
      end
      result
    end
  end

  module PostRevision
    def revise!(editor, fields, opts = {}, &block)
      fields = fields.with_indifferent_access
      FIELDS.each { |field| fields.delete(field) if fields[field].nil? }
      fields.delete(:isbf_anonymous) if fields[:isbf_anonymous].nil?
      IsbfCareers.validate_update!(editor, @post, fields)
      Post.transaction do
        result = super(editor, fields, opts, &block)
        if result && @post.is_first_post? && IsbfCareers.careers?(@post.topic)
          @post.topic.custom_fields[DESCRIPTION_FIELD] = IsbfCareers.description(@post.cooked)
          @post.topic.save_custom_fields
        end
        result
      end
    end
  end

  module HomeQueryOptions
    def build_topic_list_options
      result = super
      result[:isbf_careers_home_feed] = true if action_name == "latest"
      result
    end
  end
end