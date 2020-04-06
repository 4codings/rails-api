# frozen_string_literal: true

class BusinessesController < ApplicationController
  include Pagination
  include StripeHandler
  include SubscriptionUpdate
  before_action :authenticate_employee!, except: %i[new_review]
  before_action :authenticate_business!, except: %i[new_review]
  before_action :authenticate_location!, except: %i[new_review]

  def new_review
    @business = Business.new(business_params)
    if @business.software_tier == 'all'
      @business.subscription_tier = 'lite'
    end


    if @business.valid?
      head :no_content
    else
      render json: @business.errors, status: :unprocessable_entity
    end
  end

  def local_ip
    f = Socket.do_not_reverse_lookup
    Socket.do_not_reverse_lookup = true
    ip = IPAddr.new(request.remote_ip)
    UDPSocket.open(ip.family) do |s|
      s.connect(ip.to_s, 1)
      IPAddr.new(s.addr.last).native.to_s
    end
  ensure
    Socket.do_not_reverse_lookup = f
  end

  def request_cancellation
    @business = @current_business
    if @business.cancellation_requested.present?
      render json: @business, status: :ok
    else
      if @business.update(cancellation_requested: DateTime.current)
        @business.change_history_entries.create(employee: current_employee, message: 'Customer requested cancellation')

        BusinessMailer.request_cancellation(@business).deliver
        BusinessMailer.cancellation_received(@business, current_employee).deliver
        render json: @business, status: :ok
      else
        render json: @business, status: :unprocessable_entity
      end
    end
  end

  def index
    @businesss = Rails.cache.fetch('all-businesses') { Business.all }
  end

  def names
    query = if params[:query].present?
              params[:query]
            else
              '*'
            end
    meta = {}
    @businesses = Business.search query, fields: [:name], match: :word_start, where: { searchable: true, active: true }, order: { name: { order: :asc, unmapped_type: 'long' } }
    render json: @businesses, root: :names, each_serializer: BusinessNameSerializer, status: :ok
  end

  def show
    # @business = Rails.cache.fetch("business-model-#{@current_business.id}") do
    #   @business = Business.find(@current_business.id)
    # end
    # json = Rails.cache.fetch("business-json-#{@business.id}") do
    #   ActiveModelSerializers::SerializableResource.new(@business, include: Business::INCLUDED_MODELS_SHOW_BUSINESS).as_json
    # end

    # render json: json
    @business = @current_business
    render json: @business, include: Business::INCLUDED_MODELS_SHOW_BUSINESS
  end

  def current_inventory_info
    @business = @current_business
    render json: @business, fields: [:force_unlimited_items, :force_unlimited_serialized_items, :serialized_products_count, :products_count], include: []
  end

  def badges
    @business = @current_business
    @location = @current_location
    if @business.badges.any?
      if @business.transactions.any? && !@business.check_badges("get_paid")
        @business.complete_badge("get_paid")
      end
      render json: { badges: @current_location.badges }
    else
      @business.complete_badge("signed_up")
      render json: { badges: @business.badges }
    end
  end

  def destroy
    @business = @current_business
    @business.destroy
    head :no_content
  end

  def update
    @business = @current_business
    @business.assign_attributes(business_params)
    if @business.default_rental_changes && !@business.check_badges("rental_settings")
      @business.complete_badge("rental_settings")
    end
    if @business.save
      @business.reload
      render json: @business, include: Business::INCLUDED_MODELS_SHOW_BUSINESS
    else
      render json: @business.errors, status: :unprocessable_entity
    end
  end

  def preview_user_count_change
    @business = @current_business
    @business.available_user_count = params[:available_user_count]
    proration_data = StripeService::Subscription.preview_proration_on_user_count_change(@business)

    render json: proration_data, status: :ok
  end

  def update_available_user_count
    @business = @current_business
    @business.available_user_count = params[:available_user_count]
    StripeService::Subscription.update_available_user_count(@business)
    @business.downgrade_requested_at = nil
    @business.log_changes(name: current_employee)
    if @business.save
      @business.update_payment_type_of_members
      render json: @business, include: Business::INCLUDED_MODELS_SHOW_BUSINESS
    else
      render json: @business.errors, status: :unprocessable_entity
    end
  rescue Stripe::CardError, Stripe::InvalidRequestError => e
    body = e.json_body
    err  = body[:error]
    message = err[:message]
    render json: { message: message }, status: :unprocessable_entity
  end

  def update_billing_cycle
    @business = @current_business
    @business.billing_interval = params[:billing_interval]
    billing_notes = "Changed billing cycle from #{@business.billing_interval_was} to #{@business.billing_interval}"
    StripeService::Subscription.update_subscription(@business, billing_notes, true, current_employee)
    @business.downgrade_requested_at = nil
    if @business.save
      render json: @business, include: Business::INCLUDED_MODELS_SHOW_BUSINESS
    else
      render json: @business.errors, status: :unprocessable_entity
    end
  rescue Stripe::CardError, Stripe::InvalidRequestError => e
    body = e.json_body
    err  = body[:error]
    message = err[:message]
    render json: { message: message }, status: :unprocessable_entity
  end

  def upgrade_subscription
    @business = @current_business
    old_subscription_tier = @business.subscription_tier
    @business.subscription_tier = params[:subscription_tier]
    if multilocation_update_failed?(@business)
      render_multilocation_update_unsuccessful && return
    end
    billing_notes = "Upgraded from #{@business.subscription_tier_was.capitalize} to #{@business.subscription_tier.capitalize}"
    if @business.subscription_tier_was == 'custom'
      @business.available_user_count = @business.paid_employees_count
    end
    StripeService::Subscription.update_subscription(@business, billing_notes, true, current_employee)
    @business.downgrade_requested_at = nil
    @business.log_changes(name: current_employee)
    if @business.save
      BusinessMailer.upgrade_subscription(current_employee, @business, old_subscription_tier).deliver_now
      render json: @business, include: Business::INCLUDED_MODELS_SHOW_BUSINESS
    else
      render json: @business.errors, status: :unprocessable_entity
    end
  rescue Stripe::CardError, Stripe::InvalidRequestError => e
    body = e.json_body
    err  = body[:error]
    message = err[:message]
    render json: { message: message }, status: :unprocessable_entity
  end

  def request_downgrade
    @business = @current_business
    @business.update(downgrade_requested_at: DateTime.now)
    @business.change_history_entries.create(employee: current_employee, message: "Requested downgrade from #{@business.subscription_tier} to #{params[:subscription_tier]}.")
    BusinessMailer.downgrade_subscription(current_employee, @business, params[:subscription_tier]).deliver_now
  end

  def update_storefront_included
    @business = @current_business
    @business.storefront_included = params[:storefront_included].present?
    if @business.storefront_included
      billing_notes = "Enabled Storefront+"
    else
      billing_notes = "Disabled Storefront+"
    end
    StripeService::Subscription.update_subscription(@business, billing_notes, true, current_employee)
    @business.log_changes(name: current_employee)
    if @business.save
      render json: @business, include: Business::INCLUDED_MODELS_SHOW_BUSINESS
    else
      render json: @business.errors, status: :unprocessable_entity
    end
  rescue Stripe::CardError, Stripe::InvalidRequestError => e
    body = e.json_body
    err  = body[:error]
    message = err[:message]
    render json: { message: message }, status: :unprocessable_entity
  end

  def update_picture
    @business = @current_business
    if params[:image]
      if @business.create_picture(image: params[:image])
        render json: @business
      else
        render json: @business.errors, status: :unprocessable_entity
      end
    end
  end

  def save_bank_account
    @business = @current_business
    stripe_token = StripeService::PlaidToStripeConverter.run(bank_params[:token], bank_params[:account_id])
    stripe_account = StripeService::Customer.get_customer(@business.stripe_customer_token)
    bank_exists = StripeService::Customer.has_bank?(stripe_account, stripe_token)
    stripe_bank = if bank_exists[:success]
                    bank_exists[:bank]
                  else
                    StripeService::Customer.store_source(stripe_account, stripe_token)
                  end
    @business.bank_account = BankAccount.new(token: stripe_bank.id, fingerprint: stripe_bank.fingerprint, name: "#{stripe_bank.bank_name} #{stripe_bank.last4}")
    if @business.save
      render json: @business
    else
      render json: @business.errors, status: :unprocessable_entity
    end
  end

  def save_credit_card
    @business = @current_business
    stripe_customer = existing_business_stripe_customer
    old_credit_card = @business.credit_card
    if old_credit_card.blank?
      build_credit_card(stripe_customer); return if performed?
    else
      replace_credit_card(stripe_customer); return if performed?
    end

    if @business.save
      render json: @business
    else
      render json: @business.errors, status: :unprocessable_entity
    end
  end

  def reactivate
    @business = @current_business
    stripe_customer = existing_business_stripe_customer
    build_credit_card(stripe_customer); return if performed?
    @business.save

    if @business.reactivate!
      @business.change_history_entries.create(employee: current_employee, message: 'Reactivated Account.')
      render json: @business, status: :ok
    else
      render json: @business.errors, status: :unprocessable_entity
    end
  end

  def bulk_update_groups
    @location = @current_location
    @location.assign_attributes(business_params)
    if @location.save
      head :no_content
    else
      render json: @business.errors, status: :unprocessable_entity
    end
  end

  def orphaned_categories
    @business = @current_business
    @location = @current_location
    inventory_category_ids = @location.products.active.joins(:inventory_categorizations).distinct.pluck('inventory_categorizations.id') +
                            @location.accessories.active.joins(:inventory_categorizations).distinct.pluck('inventory_categorizations.id') +
                            @location.add_ons.active.joins(:inventory_categorizations).distinct.pluck('inventory_categorizations.id') +
                            @location.bundles.active.joins(:inventory_categorizations).distinct.pluck('inventory_categorizations.id')
    sorted_category_ids = Category.joins(:inventory_category_groups).where(inventory_category_groups: {location_id: @location.id}).distinct.pluck(:id)
    sorted_sub_category_ids = SubCategory.joins(:inventory_category_groups).where(inventory_category_groups: {location_id: @location.id}).distinct.pluck(:id)
    unsorted_category_ids = InventoryCategorization.where(id: inventory_category_ids, inventory_category_type: "Category").where.not(inventory_category_id: sorted_category_ids).pluck(:inventory_category_id)
    unsorted_sub_category_ids = InventoryCategorization.where(id: inventory_category_ids, inventory_category_type: "SubCategory").where.not(inventory_category_id: sorted_sub_category_ids).pluck(:inventory_category_id)
    inventory_categories = Category.where(id: unsorted_category_ids).distinct + SubCategory.where(id: unsorted_sub_category_ids).distinct

    render json: inventory_categories, each_serializer: InventoryCategorySerializer, status: :ok
  end

  def connect_facebook
    @business = @current_business
    @business.facebook_token = params[:token]
    FacebookService::Facebook.new(@business).refresh_facebook_token

    head :no_content
  end

  def disconnect_facebook
    @business = @current_business
    @business.update_columns(facebook_token: nil, facebook_token_expires_at: nil)

    head :no_content
  end

  def paid_employees_count
    @business = @current_business
    render json: { count: @business.paid_employees_count }
  end

  def instagram_account_info
    @business = @current_business
    if @business.facebook_token.present?
      facebook_service = FacebookService::Facebook.new(@business)
      facebook_service.refresh_facebook_token
      account_info = facebook_service.get_instagram_account_info
      if account_info.present?
        account_info['access_token'] = @business.facebook_token
      end
    else
      account_info = nil
    end

    render json: { account_info: account_info }
  end

  private

  def existing_business_stripe_customer
    Stripe::Customer.retrieve(@business.stripe_customer_token)
  end

  def build_credit_card(stripe_customer)
    @stripe_card = CreditCardForm.new(credit_card_params)
    if @stripe_card.valid?
      token = create_payment_token(credit_card_params)
      had_credit_card = @business.credit_card.present?
      stripe_card = had_credit_card ? replace_card_of_stripe_customer(stripe_customer, token.id) : add_card_to_stripe_customer(stripe_customer, token)
      @credit_card = @business.build_credit_card(
        token: stripe_card.id,
        last4: stripe_card.last4,
        card_type: stripe_card.brand,
        exp_month: stripe_card.exp_month,
        exp_year: stripe_card.exp_year
      )

      # If the business didn't have the credit card, we create subscription.
      StripeService::Subscription.create_subscription(@business) unless had_credit_card
    else
      render(json: @stripe_card.errors, status: :unprocessable_entity)
    end
  rescue Stripe::RateLimitError => e
    # Too many requests made to the API too quickly
    Airbrake.notify(e)
    render json: { message: 'Oops! An error occured during the process. Please try again later.' }, status: :internal_server_error
  rescue Stripe::AuthenticationError => e
    # Authentication with Stripe's API failed
    # (maybe you changed API keys recently)
    Airbrake.notify(e)
    render json: { message: 'Oops! An error occured during the process. Please try again later.' }, status: :internal_server_error
  rescue Stripe::APIConnectionError => e
    # Network communication with Stripe failed
    Airbrake.notify(e)
    render json: { message: 'Oops! An error occured during the process. Please try again later.' }, status: :internal_server_error
  rescue Stripe::CardError, Stripe::InvalidRequestError => e
    body = e.json_body
    err  = body[:error]
    message = err[:message]
    render json: { message: message }, status: :unprocessable_entity
  end

  def replace_credit_card(stripe_customer)
    @stripe_card = CreditCardForm.new(credit_card_params)
    if @stripe_card.valid?
      token = create_payment_token(credit_card_params)
      stripe_card = replace_card_of_stripe_customer(stripe_customer, token.id)
      @credit_card = @business.credit_card.update(
        token: stripe_card.id,
        last4: stripe_card.last4,
        card_type: stripe_card.brand,
        exp_month: stripe_card.exp_month,
        exp_year: stripe_card.exp_year
      )
    else
      render(json: @stripe_card.errors, status: :unprocessable_entity)
    end
  rescue Stripe::RateLimitError => e
    # Too many requests made to the API too quickly
    Airbrake.notify(e)
    render json: { message: 'Oops! An error occured during the process. Please try again later.' }, status: :internal_server_error
  rescue Stripe::AuthenticationError => e
    # Authentication with Stripe's API failed
    # (maybe you changed API keys recently)
    Airbrake.notify(e)
    render json: { message: 'Oops! An error occured during the process. Please try again later.' }, status: :internal_server_error
  rescue Stripe::APIConnectionError => e
    # Network communication with Stripe failed
    Airbrake.notify(e)
    render json: { message: 'Oops! An error occured during the process. Please try again later.' }, status: :internal_server_error
  rescue Stripe::CardError, Stripe::InvalidRequestError => e
    body = e.json_body
    err  = body[:error]
    message = err[:message]
    render json: { message: message }, status: :unprocessable_entity
  end

  def business_params
    params.require(:business).permit(:name, :subdomain, :website, :badges, :email, :signature_required,
                                     :deposit_fixed_fee, :deposit_percent, :software_tier,
                                     :storefront_tier, :yearly_revenue_estimate,
                                     :damage_waiver_fixed_fee, :damage_waiver_percent, :damage_waiver_tax_exempt,
                                     :credit_card_percent,
                                     :expire_days_before, :expire_days_after, :expire_from_field, :rentals_expire,
                                     :default_start, :default_end, :auto_reserve_enabled, :propay_country,
                                     :show_routing_assignments, :default_setup_time,
                                     :should_send_emails_from_user, :from_email_type, :custom_reply_to_email,
                                     :show_inventory_photo_in_emails, :show_inventory_photo_in_pdf, :show_soft_holds,
                                     :show_unit_pricing_to_customers, :show_subtotals_in_sections,
                                     :sales_tax_type, :custom_sales_tax_percent,
                                     :minimum_item_total_for_pickup, :minimum_item_total_for_delivery,
                                     :payment_reminder_options, :should_allow_auto_book, :auto_book_minimum_days_after,
                                     :default_agreement_id,
                                     reminder_email_attributes: %i[id should_send days_before days_after should_send_follow_up
                                                                   follow_up_days_before follow_up_days_after custom_email_note custom_subject],
                                     expire_email_attributes: %i[id should_send days_before custom_email_note custom_subject],
                                     cc_email_attributes: %i[id should_send custom_subject],
                                     quote_email_attributes: %i[id should_send custom_email_note custom_subject],
                                     action_request_email_attributes: %i[id should_send custom_email_note custom_subject],
                                     quote_pending_email_attributes: %i[id should_send custom_email_note custom_subject],
                                     quote_approved_email_attributes: %i[id should_send custom_email_note custom_subject],
                                     quote_denied_email_attributes: %i[id should_send custom_email_note custom_subject],
                                     sf_quote_pending_email_attributes: %i[id should_send custom_email_note custom_subject],
                                     sf_quote_approved_email_attributes: %i[id should_send custom_email_note custom_subject],
                                     sf_quote_denied_email_attributes: %i[id should_send custom_email_note custom_subject],
                                     mp_quote_pending_email_attributes: %i[id should_send custom_email_note custom_subject],
                                     mp_quote_approved_email_attributes: %i[id should_send custom_email_note custom_subject],
                                     mp_quote_denied_email_attributes: %i[id should_send custom_email_note custom_subject],
                                     picklist_email_attributes: %i[id should_send custom_email_note custom_subject],
                                     invoice_address_attributes: %i[id should_send custom_email_note custom_subject],
                                     staff_reminder_attributes: %i[id should_send custom_email_note custom_subject],
                                     customer_welcome_attributes: %i[id should_send custom_email_note custom_subject],
                                     signature_confirmation_email_attributes: %i[id should_send custom_email_note custom_subject],
                                     payment_confirmation_email_attributes: %i[id should_send custom_email_note custom_subject],
                                     payment_reminder_email_attributes: %i[id should_send custom_email_note custom_subject],
                                     reservation_email_attributes: %i[id should_send custom_email_note custom_subject],
                                     summary_email_attributes: %i[id should_send custom_email_note custom_subject],
                                     closed_email_attributes: %i[id should_send custom_email_note custom_subject],
                                     nps_email_attributes: %i[id should_send custom_email_note custom_subject],
                                     proposal_email_attributes: %i[id should_send custom_email_note custom_subject],
                                     autobooked_email_attributes: %i[id should_send custom_email_note custom_subject],
                                     team_member_assigned_email_attributes: %i[id should_send],

                                     agreement_attributes: [:description],
                                     business_payment_terms_attributes: [:id, :content, :_destroy],
                                     rental_agreements_attributes: [
                                       :id, :title, :description, :_destroy,
                                       customer_rental_agreement_relationships_attributes: %i[id customer_location_relationship_id _destroy],
                                       company_rental_agreement_relationships_attributes: %i[id company_id _destroy]
                                     ],
                                     picklist_clause_attributes: [:description],
                                     permission_settings_attributes: %i[id allowed_roles setting_type],
                                     picture_attributes: %i[id image _destroy],
                                     physical_address_attributes: %i[id tax_rate street_address_1 street_address_2 city locale postal_code country],
                                     phone_number_attributes: %i[id office cell fax main_contact_number],
                                     stripe_subscription_attributes: [:id, :amount, :trial_end],
                                     inventory_category_groups_attributes: [
                                      :id, :name, :active, :_destroy,
                                      inventory_category_groupings_attributes: [
                                        :id, :inventory_category_id, :inventory_category_type,
                                        :position, :active, :_destroy]
                                     ],
                                     employees_attributes: [:first_name, :last_name, :password, :password_confirmation, :confirmed_at, :role, :email, :uid, :provider,
                                                            physical_address_attributes: %i[street_address_1 street_address_2 city locale postal_code country],
                                                            phone_number_attributes: %i[office cell fax main_contact_number]])
  end

  def bank_params
    params.require(:bank).permit(:name, :token, :account_id)
  end

  def credit_card_params
    params.require(:credit_card).permit(:token, :name, :cvc, :number, :exp_month, :exp_year,
                                        :street_address1, :street_address2, :city, :locale, :postal_code, :country, :phone_number)
  end
end
