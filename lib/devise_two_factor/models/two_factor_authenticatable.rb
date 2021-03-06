require 'attr_encrypted'
require 'rotp'

module Devise
  module Models
    module TwoFactorAuthenticatable
      extend ActiveSupport::Concern
      include Devise::Models::DatabaseAuthenticatable

      included do
        unless singleton_class.ancestors.include?(AttrEncrypted)
          extend AttrEncrypted
        end

        unless attr_encrypted?(:otp_secret)
          attr_encrypted :otp_secret,
            :key  => self.otp_secret_encryption_key,
            :mode => :per_attribute_iv_and_salt unless self.attr_encrypted?(:otp_secret)
        end

        attr_accessor :otp_attempt
      end

      def self.required_fields(klass)
        [:encrypted_otp_secret, :encrypted_otp_secret_iv, :encrypted_otp_secret_salt, :consumed_timestep]
      end

      def update_with_otp(params)
        current_otp = params.delete(:otp_attempt).to_s
        if(self.otp_required_for_login?)
          if(valid_otp?(current_otp))
            update(params) && validate_and_consume_otp!(current_otp)
          else
            assign_attributes(params)
            valid?
            errors.add(:otp_attempt, :already_consumed) if already_consumed?
            errors.add(:otp_attempt, current_otp.blank? ? :blank : :invalid)
            false
          end
        else
          return update(params)
        end
      end

      def update_with_otp_and_password(params)
        otp_attempt = params.delete(:otp_attempt).to_s
        if(self.otp_required_for_login?)
          if(valid_otp?(otp_attempt))
            update_with_password(params) && validate_and_consume_otp!(otp_attempt)
          else
            params.delete(:current_password)
            assign_attributes(params)
            valid?
            errors.add(:otp_attempt, :already_consumed) if already_consumed?
            errors.add(:otp_attempt, otp_attempt.blank? ? :blank : :invalid)
            false
          end
        else
          return update_with_password(params)
        end
      end

      def valid_otp?(otp)
        totp = self.otp(otp_secret)
        !already_consumed? && totp.verify_with_drift(otp, self.class.otp_allowed_drift)
      end

      def already_consumed?
        self.consumed_timestep == current_otp_timestep
      end

      # This defaults to the model's otp_secret
      # If this hasn't been generated yet, pass a secret as an option
      def validate_and_consume_otp!(code, options = {})
        otp_secret = options[:otp_secret] || self.otp_secret
        return false unless code.present? && otp_secret.present?

        totp = self.otp(otp_secret)
        return consume_otp! if totp.verify_with_drift(code, self.class.otp_allowed_drift)

        false
      end

      def otp(otp_secret = self.otp_secret)
        ROTP::TOTP.new(otp_secret)
      end

      def current_otp
        otp.at(Time.now)
      end

      # ROTP's TOTP#timecode is private, so we duplicate it here
      def current_otp_timestep
         Time.now.utc.to_i / otp.interval
      end

      def otp_provisioning_uri(account, options = {})
        otp_secret = options[:otp_secret] || self.otp_secret
        ROTP::TOTP.new(otp_secret, options).provisioning_uri(account)
      end

      def clean_up_passwords
        self.otp_attempt = nil
      end



    protected

      # An OTP cannot be used more than once in a given timestep
      # Storing timestep of last valid OTP is sufficient to satisfy this requirement
      def consume_otp!
        unless already_consumed?
          self.consumed_timestep = current_otp_timestep
          return save(validate: false)
        end
        false
      end

      module ClassMethods
        Devise::Models.config(self, :otp_secret_length,
                                    :otp_allowed_drift,
                                    :otp_secret_encryption_key)

        def generate_otp_secret(otp_secret_length = self.otp_secret_length)
          ROTP::Base32.random_base32(otp_secret_length)
        end
      end


    end
  end
end
