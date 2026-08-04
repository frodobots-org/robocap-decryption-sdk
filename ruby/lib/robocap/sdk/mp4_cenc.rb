# frozen_string_literal: true

require 'base64'
require 'json'
require 'pathname'
require_relative 'config'
require_relative 'errors'
require_relative 'ffmpeg_cli'

module RobocapCenc
  module SDK
    PRODUCT_LINE_ROBOCAP   = 'robocap'
    PRODUCT_LINE_ROBOWRIST = 'robowrist'
    PRODUCT_LINE_LEGACY    = 'legacy'

    PRODUCT_LINES = [
      PRODUCT_LINE_ROBOCAP,
      PRODUCT_LINE_ROBOWRIST,
      PRODUCT_LINE_LEGACY,
    ].freeze

    CencMp4Metadata = Data.define(
      :customer_id, :cek_wrapped, :kid_hex, :product_line, :tag_deviceid, :tag_host,
    ) do
      def initialize(customer_id:, cek_wrapped:, kid_hex: nil,
                     product_line: PRODUCT_LINE_LEGACY, tag_deviceid: nil, tag_host: nil)
        super
      end
    end

    module Mp4Cenc
      CEKA_TAG                 = 'cenc_cek_wrapped_b64'
      CUSTOMER_ID_TAG          = 'cenc_customer_id'
      CUSTOMER_ID_FALLBACK_TAG = 'deviceid'
      HOST_TAG                 = 'host'
      KID_TAG                  = 'cenc_kid_hex'

      CENC_WRAPPED_ALGO_TAG = 'cenc_wrapped_algo'

      CENC_STRIP_TAGS_ON_DECRYPT = [
        CEKA_TAG,
        CENC_WRAPPED_ALGO_TAG,
      ].freeze

      module_function

      def read_format_tags(mp4_path, ffprobe_executable: nil)
        path = Pathname(mp4_path).expand_path
        unless path.file?
          raise Error.new(
            code: ErrorCode::ERR_CENC_TAGS_MISSING,
            message: "MP4 file not found: #{path}",
          )
        end
        exe = FfmpegCli.resolve_ffprobe_executable(ffprobe_executable)
        stdout, stderr, status = FfmpegCli.open3_capture3(
          exe, '-v', 'error', '-show_format', '-print_format', 'json', path.to_s,
        )
        unless status.exitstatus.zero?
          raise Error.new(
            code: ErrorCode::ERR_CENC_FFPROBE_FAILED,
            message: "ffprobe failed: #{stderr}",
          )
        end

        payload = parse_ffprobe_json(stdout)
        fmt = payload['format']
        unless fmt.is_a?(Hash)
          raise Error.new(
            code: ErrorCode::ERR_CENC_TAGS_MISSING,
            message: 'ffprobe output missing format section',
          )
        end
        tags = fmt['tags']
        unless tags.is_a?(Hash)
          raise Error.new(
            code: ErrorCode::ERR_CENC_TAGS_MISSING,
            message: 'MP4 has no format metadata tags',
          )
        end
        tags.transform_keys(&:to_s).transform_values(&:to_s)
      end

      # Product line is derived from the filename prefix, which decides whether
      # the vault is keyed by the +deviceid+ or the +host+ tag.
      def detect_product_line(mp4_path)
        stem = Pathname(mp4_path).basename('.*').to_s.downcase
        return PRODUCT_LINE_ROBOWRIST if stem.start_with?('robowrist_')
        return PRODUCT_LINE_ROBOCAP if stem.start_with?('robocap_')
        PRODUCT_LINE_LEGACY
      end

      def parse_cenc_metadata_from_tags(tags, mp4_path: nil, product_line: nil)
        unless tags[CEKA_TAG] && !tags[CEKA_TAG].empty?
          raise Error.new(
            code: ErrorCode::ERR_CENC_TAGS_MISSING,
            message: "Missing CENC tags: #{CEKA_TAG}",
          )
        end

        line = product_line
        line ||= mp4_path ? detect_product_line(mp4_path) : PRODUCT_LINE_LEGACY

        customer_id = resolve_vault_customer_id(tags, line)

        begin
          cek_wrapped = Base64.strict_decode64(tags[CEKA_TAG])
        rescue ArgumentError
          raise Error.new(
            code: ErrorCode::ERR_CENC_TAGS_MISSING,
            message: 'Invalid cenc_cek_wrapped_b64 Base64',
          )
        end

        unless cek_wrapped.bytesize == Config::RSA_2048_CIPHERTEXT_BYTES
          raise Error.new(
            code: ErrorCode::ERR_CENC_CEKA_WRAP,
            message: "Wrapped CEK must be #{Config::RSA_2048_CIPHERTEXT_BYTES} bytes",
          )
        end

        kid = tags[KID_TAG]
        kid = kid.strip.downcase if kid
        kid = nil if kid && kid.empty?

        CencMp4Metadata.new(
          customer_id: customer_id,
          cek_wrapped: cek_wrapped,
          kid_hex: kid,
          product_line: line,
          tag_deviceid: tag_value(tags, CUSTOMER_ID_FALLBACK_TAG) || tag_value(tags, CUSTOMER_ID_TAG),
          tag_host: tag_value(tags, HOST_TAG),
        )
      end

      def load_cenc_metadata(mp4_path, ffprobe_executable: nil)
        path = Pathname(mp4_path).expand_path
        tags = read_format_tags(path, ffprobe_executable: ffprobe_executable)
        parse_cenc_metadata_from_tags(
          tags, mp4_path: path, product_line: detect_product_line(path),
        )
      end

      def has_cenc_tags(mp4_path, ffprobe_executable: nil)
        path = Pathname(mp4_path).expand_path
        tags = read_format_tags(path, ffprobe_executable: ffprobe_executable)
        has_required_tags_for_product?(tags, detect_product_line(path))
      rescue Error
        false
      end

      # Binds a caller-supplied device id to the tags embedded in the MP4 so a
      # capture cannot be decrypted under a different device's session.
      def verify_session_device_id(session_device_id, tags, product_line)
        normalized = normalize_session_device_id(session_device_id)

        if product_line == PRODUCT_LINE_ROBOWRIST
          expected = tag_value(tags, HOST_TAG)
          field = HOST_TAG
        else
          expected = tag_value(tags, CUSTOMER_ID_TAG) || tag_value(tags, CUSTOMER_ID_FALLBACK_TAG)
          field = CUSTOMER_ID_TAG
        end

        assert_session_device_id_matches(expected, normalized, field)
      end

      def verify_session_device_id_from_metadata(session_device_id, meta)
        normalized = normalize_session_device_id(session_device_id)

        if meta.product_line == PRODUCT_LINE_ROBOWRIST
          expected = meta.tag_host
          field = HOST_TAG
        else
          expected = meta.tag_deviceid
          field = CUSTOMER_ID_FALLBACK_TAG
        end

        assert_session_device_id_matches(expected, normalized, field)
      end

      class << self
        private

        def parse_ffprobe_json(raw)
          JSON.parse(raw)
        rescue JSON::ParserError
          raise Error.new(
            code: ErrorCode::ERR_CENC_FFPROBE_FAILED,
            message: 'ffprobe returned invalid JSON',
          )
        end

        def tag_value(tags, key)
          raw = tags[key]
          return nil if raw.nil?
          stripped = raw.strip
          stripped.empty? ? nil : stripped
        end

        def validate_customer_id_string(customer_id)
          Config.validate_customer_id!(customer_id)
          customer_id
        rescue ArgumentError
          raise Error.new(
            code: ErrorCode::ERR_CENC_CUSTOMER_ID_INVALID,
            message: "Invalid customer id: #{customer_id.inspect}",
          )
        end

        def resolve_deviceid_from_tags(tags)
          raw = tags[CUSTOMER_ID_TAG] || tags[CUSTOMER_ID_FALLBACK_TAG]
          if raw.nil? || raw.strip.empty?
            raise Error.new(
              code: ErrorCode::ERR_CENC_TAGS_MISSING,
              message: "Missing CENC customer id: #{CUSTOMER_ID_TAG} or #{CUSTOMER_ID_FALLBACK_TAG} tag required",
            )
          end
          validate_customer_id_string(raw.strip)
        end

        def resolve_vault_customer_id(tags, product_line)
          if product_line == PRODUCT_LINE_ROBOWRIST
            host = tag_value(tags, HOST_TAG)
            if host.nil?
              raise Error.new(
                code: ErrorCode::ERR_CENC_TAGS_MISSING,
                message: "Missing CENC host tag for robowrist: #{HOST_TAG} required",
              )
            end
            return validate_customer_id_string(host)
          end
          resolve_deviceid_from_tags(tags)
        end

        def has_customer_id_source?(tags)
          [CUSTOMER_ID_TAG, CUSTOMER_ID_FALLBACK_TAG].any? { |k| !tag_value(tags, k).nil? }
        end

        def has_required_tags_for_product?(tags, product_line)
          return false unless tags[CEKA_TAG] && !tags[CEKA_TAG].empty?
          if product_line == PRODUCT_LINE_ROBOWRIST
            return !tag_value(tags, HOST_TAG).nil? && has_customer_id_source?(tags)
          end
          has_customer_id_source?(tags)
        end

        def normalize_session_device_id(session_device_id)
          normalized = session_device_id.to_s.strip
          if normalized.empty?
            raise Error.new(
              code: ErrorCode::ERR_DEVICE_BINDING_MISMATCH,
              message: 'Session device id is empty',
            )
          end
          begin
            Config.validate_customer_id!(normalized)
          rescue ArgumentError
            raise Error.new(
              code: ErrorCode::ERR_DEVICE_BINDING_MISMATCH,
              message: "Invalid session device id: #{normalized.inspect}",
            )
          end
          normalized
        end

        def assert_session_device_id_matches(expected, normalized, field)
          return if !expected.nil? && expected == normalized
          raise Error.new(
            code: ErrorCode::ERR_DEVICE_BINDING_MISMATCH,
            message: "Session device id does not match MP4 #{field} tag",
          )
        end
      end
    end
  end
end
