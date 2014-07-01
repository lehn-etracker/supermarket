require 'cookbook_upload'
require 'mixlib/authentication/signatureverification'

class Api::V1::CookbookUploadsController < Api::V1Controller
  before_filter :require_upload_params, only: :create
  before_filter :authenticate_user!

  attr_reader :current_user

  #
  # POST /api/v1/cookbooks
  #
  # Accepts cookbooks to share. A sharing request is a multipart POST. Two of
  # those parts are relevant to this method: +cookbook+ and +tarball+.
  #
  # The +cookbook+ part is a serialized JSON object which must contain a
  # +"category"+ key. The value of this key is the name of the category to
  # which this cookbook belongs.
  #
  # The +tarball+ part is a gzipped tarball containing the cookbook. Crucially,
  # this tarball must contain a +metadata.json+ entry, which is typically
  # generated by knife, and derived from the cookbook's +metadata.rb+.
  #
  # There are two use cases for sharing a cookbook: adding a new cookbook to
  # the community site, and updating an existing cookbook. Both are handled by
  # this action.
  #
  # There are also several failure modes for sharing a cookbook. These include,
  # but are not limited to, forgetting to specify a category, specifying a
  # non-existent category, forgetting to upload a tarball, uploading a tarball
  # without a metadata.json entry, and so forth.
  #
  # The majority of the work happens between +CookbookUpload+,
  # +CookbookUpload::Parameters+, and +Cookbook+
  #
  # @see Cookbook
  # @see CookbookUpload
  # @see CookbookUpload::Parameters
  #
  def create
    cookbook_upload = CookbookUpload.new(current_user, upload_params)

    begin
      authorize! cookbook_upload.cookbook
    rescue
      error(
        error_code: t('api.error_codes.unauthorized'),
        error_messages: [t('api.error_messages.unauthorized_upload_error')]
      )
    else
      cookbook_upload.finish do |errors, cookbook|
        if errors.any?
          error(
            error: t('api.error_codes.invalid_data'),
            error_messages: errors.full_messages
          )
        else
          @cookbook = cookbook

          CookbookNotifyWorker.perform_async(@cookbook.id)

          SegmentIO.track_server_event(
            'cookbook_version_published',
            current_user,
            cookbook: @cookbook.name
          )

          Rails.cache.delete(Api::V1::UniverseController::CACHE_KEY)

          render :create, status: 201
        end
      end
    end
  end

  #
  # DELETE /api/v1/cookbooks/:cookbook
  #
  # Destroys the specified cookbook. If it does not exist, return a 404.
  #
  # @example
  #   DELETE /api/v1/cookbooks/redis
  #
  def destroy
    @cookbook = Cookbook.with_name(params[:cookbook]).first!

    begin
      authorize! @cookbook
    rescue
      error({}, 403)
    else
      @latest_cookbook_version_url = api_v1_cookbook_version_url(
        @cookbook, @cookbook.latest_cookbook_version
      )

      @cookbook.destroy

      if @cookbook.destroyed?
        CookbookDeletionWorker.perform_async(@cookbook.as_json)
        SegmentIO.track_server_event(
          'cookbook_deleted',
          current_user,
          cookbook: @cookbook.name
        )

        Rails.cache.delete(Api::V1::UniverseController::CACHE_KEY)
      end
    end
  end

  rescue_from ActionController::ParameterMissing do |e|
    error(
      error_code: t('api.error_codes.invalid_data'),
      error_messages: [t("api.error_messages.missing_#{e.param}")]
    )
  end

  rescue_from Mixlib::Authentication::AuthenticationError do |_e|
    error(
      error_code: t('api.error_codes.authentication_failed'),
      error_messages: [t('api.error_messages.authentication_request_error')]
    )
  end

  private

  def error(body, status = 400)
    render json: body, status: status
  end

  #
  # The parameters required to upload a cookbook
  #
  # @raise [ActionController::ParameterMissing] if the +:cookbook+ parameter is
  #   missing
  # @raise [ActionController::ParameterMissing] if the +:tarball+ parameter is
  #   missing
  #
  def upload_params
    {
      cookbook: params.require(:cookbook),
      tarball: params.require(:tarball)
    }
  end

  alias_method :require_upload_params, :upload_params

  #
  # Finds a user specified in the request header or renders an error if
  # the user doesn't exist. Then attempts to authorize the signed request
  # against the users public key or renders an error if it fails.
  #
  def authenticate_user!
    username = request.headers['X-Ops-Userid']
    user = Account.for('chef_oauth2').where(username: username).first.try(:user)

    unless user
      return error(
        {
          error_code: t('api.error_codes.authentication_failed'),
          error_messages: [t('api.error_messages.invalid_username', username: username)]
        },
        401
      )
    end

    if user.public_key.nil?
      return error(
        {
          error_code: t('api.error_codes.authentication_failed'),
          error_messages: [t('api.error_messages.missing_public_key_error', current_host: request.base_url)]
        },
        401
      )
    end

    auth = Mixlib::Authentication::SignatureVerification.new.authenticate_user_request(
      request,
      OpenSSL::PKey::RSA.new(user.public_key)
    )

    if auth
      @current_user = user
    else
      error(
        {
          error_code: t('api.error_codes.authentication_failed'),
          error_messages: [t('api.error_messages.authentication_key_error')]
        },
        401
      )
    end
  end
end
