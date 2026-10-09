# typed: false

class ApplicationController < ActionController::Base
  include IntervalHelper
  include Authenticatable
  include ApplicationHelper

  protect_from_forgery
  prepend_before_action :prepare_exception_notifier # first in case others raise
  before_action :heinous_inline_partials, if: -> { Rails.env.development? }
  before_action :mini_profiler
  before_action :set_traffic_style
  before_action :remove_unknown_cookies
  after_action :clear_session_cookie

  SESSION_DEFAULT_KEYS = %w[session_id _csrf_token]
  # match this in caddy config for bypassing the file cache
  TAG_FILTER_COOKIE = :tag_filters
  CACHE_PAGE = proc { @user.blank? && cookies[TAG_FILTER_COOKIE].blank? && clear_session_cookie? }

  # copied from https://github.com/rack/rack/blob/main/lib/rack/utils.rb
  VALID_COOKIE_KEY = /\A[!#$%&'*+\-.\^_`|~0-9a-zA-Z]+\z/
  ANUBIS_COOKIE_PREFIX = "techaro.lol-anubis"

  # Rails misdesign: if the /recent route doesn't support .rss, Rails calls it anyways and then
  # raises MissingTemplate when it's not handled, as if the app did something wrong (a prod 500!).
  unless Rails.env.development?
    rescue_from ActionController::UnknownFormat, ActionView::MissingTemplate do
      request.format = :html # required, despite format.any
      respond_to do |format|
        format.any { render "about/404", status: :not_found, content_type: "text/html" }
      end
    end
  end
  rescue_from ActionController::UnpermittedParameters do
    respond_to do |format|
      format.html { render plain: "400 Unpermitted query or form parameter", status: :bad_request }
      format.json { render json: {error: "400 Unpermitted query or form parameter"}, status: :bad_request }
    end
  end
  rescue_from ActionController::ParameterMissing do |exception|
    respond_to do |format|
      format.html { render plain: "400 #{exception.message}", status: :bad_request }
      format.json { render json: {error: exception.message.to_s}, status: :bad_request }
    end
  end
  rescue_from ActionDispatch::Http::MimeNegotiation::InvalidType do
    render plain: "fix the mime type in your HTTP_ACCEPT header",
      status: :bad_request, content_type: "text/plain"
  end
  rescue_from ActionDispatch::RemoteIp::IpSpoofAttackError do
    render plain: RejectSpoofedIps::MESSAGE, status: :bad_request, content_type: "text/plain"
  end
  rescue_from ActiveRecord::ConnectionNotEstablished do
    render plain: "500 The database is not taking our calls.", status: 500, content_type: "text/plain"
  end

  def agent_is_spider?
    ua = request.env["HTTP_USER_AGENT"].to_s
    ua == "" || ua.match(/(Google|bing|Slack|Twitter)bot|Slurp|crawler|Feedly|FeedParser|RSS/)
  end

  def check_for_read_only_mode
    if Rails.application.read_only?
      flash.now[:error] = "Site is currently in read-only mode."
      return redirect_to "/"
    end

    true
  end

  def remove_unknown_cookies
    cookies.each do |key, _value|
      next if key == TAG_FILTER_COOKIE.to_s # don't clear tag filters cookie
      next if key == Rails.application.config.session_options[:key] # don't clear session cookie
      next if key == "__profilin" && (Rails.env.development? || @user&.is_moderator?) # don't clear Rack::MiniProfiler cookie
      next if key.start_with?(ANUBIS_COOKIE_PREFIX)
      next unless VALID_COOKIE_KEY.match?(key)
      cookies.delete(key)
    end
  end

  # clear Rails session cookie if not logged in so caddy uses the page cache
  # https://ryanfb.xyz/etc/2021/08/29/going_cookie-free_with_rails.html
  def clear_session_cookie
    if clear_session_cookie?
      key = Rails.application.config.session_options[:key] # "lobster_trap"
      cookies.delete(key)
      request.session_options[:skip] = true
    end
  end

  def clear_session_cookie?
    # If the session has been loaded, it will contain some default keys and not
    # be `empty?`
    !@user && session.keys.all? { |k| SESSION_DEFAULT_KEYS.include?(k.to_s) } && flash.empty?
  end

  def find_user_from_rss_token
    if !@user && params[:format] == "rss" && params[:token].to_s.present?
      @user = User.where(rss_token: params[:token].to_s).first
      Telebugs.user id: @user&.token, username: @user&.username, email: @user&.email, ip_address: request.remote_ip
    end
  end

  def heinous_inline_partials
    do_heinous_inline_partial_replacement
  end

  def mini_profiler
    if @user&.is_moderator?
      Rack::MiniProfiler.authorize_request
    end
  end

  def prepare_exception_notifier
    if Rails.application.config.exception_notifier
      exception_data = {}
      exception_data[:username] = @user.username unless @user.nil?
      request.env["exception_notifier.exception_data"] = exception_data
    end

    if Rails.application.config.telebugs
      Telebugs.context "request", {
        requested_path: @requested_path,
        original_fullpath: request.original_fullpath,
        query_parameters: request.query_parameters, # protected by filter_parameters
        request_parameters: request.request_parameters, # protected by filter_parameters
        git_head: LOBSTERS_GIT_HEAD
      }
      Telebugs.user id: nil, username: nil, email: nil, ip_address: request.remote_ip # authenticate_user overwrites
    end
  end

  def refill_story_page_cache(story, is_moderator: false)
    # an unauthed hit to an edit action would fail to load @story, then call this
    return if !story

    if (story.is_gone? || story.merged_story_id || story.new_record?) && story.short_id.present? && page_cache_directory.present?
      # rm the story's whole directory to catch files with old title slugs
      FileUtils.rm_rf File.join(page_cache_directory, "s", story.short_id)
    else
      CachePageJob
        .set(
          queue: (is_moderator || story.created_at&.after?(1.month.ago)) ? :default : :refill_story_pages,
          wait: is_moderator ? 0 : 2.minutes
        )
        .perform_later(Routes.title_path(story))
    end
  end

  # https://web.archive.org/web/20180108083712/http://umaine.edu/lobsterinstitute/files/2011/12/LobsterColorsWeb.pdf
  def set_traffic_style
    @traffic_intensity = "?"
    @traffic_style = "background-color: #000000;"
    return true
  end

  def require_no_user_or_redirect
    redirect_to "/" if @user
  end

  def show_title_h1
    @title_h1 = true
  end
end
