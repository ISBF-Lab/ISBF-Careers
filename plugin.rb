# frozen_string_literal: true

# name: isbf-careers
# about: Native careers topics with opt-in home display and named posting.
# version: 0.1.0
# authors: ISBF Lab
# url: https://github.com/ISBF-Lab/ISBF-Careers
# required_version: 3.4.0

require_relative "app/validators/isbf_careers_category_id_validator"

enabled_site_setting :isbf_careers_enabled

after_initialize do
  require_relative "lib/isbf_careers"
  require_relative "lib/isbf_careers/controllers"

  { IsbfCareers::HOME_FIELD => :boolean, IsbfCareers::SALARY_FIELD => :string,
    IsbfCareers::DESCRIPTION_FIELD => :string }.each do |field, type|
    register_topic_custom_field_type(field, type)
    add_preloaded_topic_list_custom_field(field)
  end
  IsbfCareers::FIELDS.each do |field|
    add_permitted_post_create_param(field.to_sym, :string)
    allow_new_queued_post_payload_attribute(field.to_sym)
    add_permitted_post_update_param(field.to_sym) do |post, value|
      if !value.nil? && !post.is_first_post?
        raise Discourse::InvalidParameters.new(field)
      end
    end
    PostRevisor.track_topic_field(field.to_sym) do |changes, value|
      next if value.nil?
      raise Discourse::InvalidAccess unless IsbfCareers.careers?(changes.topic)
      normalized = field == IsbfCareers::HOME_FIELD ? IsbfCareers.home_flag(value) : IsbfCareers.salary(value)
      changes.record_change(field, changes.topic.custom_fields[field], normalized)
      changes.topic.custom_fields[field] = normalized
    end
  end
  add_permitted_post_create_param(:isbf_anonymous, :string)
  add_permitted_post_update_param(:isbf_anonymous) do |post, value|
    IsbfCareers.reject_anonymous!(post.user, isbf_anonymous: value) if IsbfCareers.careers?(post.topic)
  end

  %i[topic_view topic_list_item].each do |serializer|
    add_to_serializer(serializer, :isbf_careers) do
      topic = object.respond_to?(:topic) ? object.topic : object
      IsbfCareers.metadata(topic)
    end
  end
  add_to_serializer(:post, :isbf_careers, include_condition: -> { object.is_first_post? }) do
    IsbfCareers.metadata(object.topic)
  end
  add_to_serializer(:site, :isbf_careers, include_condition: -> { IsbfCareers.category_id && Category.exists?(id: IsbfCareers.category_id) }) do
    {
      category_id: IsbfCareers.category_id,
      enabled: SiteSetting.isbf_careers_enabled,
      publishing_enabled: SiteSetting.isbf_careers_publishing_enabled,
      version: 1,
      salary_max_length: IsbfCareers::SALARY_MAX_LENGTH,
    }
  end

  NewPostManager.add_handler(-100) do |manager|
    next unless SiteSetting.isbf_careers_enabled
    next unless IsbfCareers.target?(manager.args) || IsbfCareers.supplied?(manager.args)
    begin
      home = IsbfCareers.validate_creation!(manager.user, manager.args, guardian: Guardian.new(manager.args[:acting_user] || manager.user))
      # Native queue payload handling drops false booleans; strings retain either choice.
      manager.args[IsbfCareers::HOME_FIELD.to_sym] = home.to_s if manager.args[:topic_id].blank?
      manager.args[IsbfCareers::SALARY_FIELD.to_sym] = IsbfCareers.salary(manager.args[IsbfCareers::SALARY_FIELD.to_sym])
      nil
    rescue Discourse::InvalidParameters, Discourse::InvalidAccess
      result = NewPostResult.new(:create_post, false)
      result.errors.add(:base, I18n.t("isbf_careers.invalid"))
      result
    end
  end

  on(:before_create_topic) do |topic, creator|
    next unless IsbfCareers.careers?(topic)
    home = IsbfCareers.validate_creation!(creator.user, creator.opts, guardian: creator.guardian)
    topic.custom_fields[IsbfCareers::HOME_FIELD] = home
    topic.custom_fields[IsbfCareers::SALARY_FIELD] = IsbfCareers.salary(creator.opts[IsbfCareers::SALARY_FIELD.to_sym])
    topic.custom_fields[IsbfCareers::DESCRIPTION_FIELD] = IsbfCareers.description(PrettyText.cook(creator.opts[:raw]))
  end

  on(:before_edit_post) { |post, _fields| IsbfCareers.validate_post_author!(post) }
  PostCreator.prepend(IsbfCareers::PostCreation)
  PostRevisor.prepend(IsbfCareers::PostRevision)

  ListController.prepend(IsbfCareers::HomeQueryOptions)
  TopicQuery.add_custom_filter(:isbf_careers_home_feed) do |topics, query|
    if query.options[:isbf_careers_home_feed] && query.options[:category].blank? &&
         query.options[:tags].blank? && query.options[:q].blank?
      IsbfCareers.home_scope(topics)
    else
      topics
    end
  end
  add_filter_custom_filter("isbf-careers") { |scope, values, guardian| IsbfCareers.filter(scope, values, guardian) }

  IsbfCareers::Engine.routes.draw { get "/" => "topics#page" }
  Discourse::Application.routes.append { mount ::IsbfCareers::Engine, at: "/isbf/careers" }
end