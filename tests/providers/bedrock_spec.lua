local bedrock_provider = require("avante.providers.bedrock")

local test_util = require("avante.utils.test")
local Config = require("avante.config")
Config.setup({})

describe("bedrock_provider", function()
  describe("parse_stream_data", function()
    it("should parse response in a stream.", function()
      local data = test_util.read_file("tests/data/bedrock_response_stream.bin")
      local message = ""
      bedrock_provider:parse_stream_data({}, data, {
        on_chunk = function(msg) message = message .. msg end,
        on_stop = function() end,
      })
      assert.equals(
        "I'll help you fix errors in the HelloLog4j.java file. Let me first understand what errors might be present by examining the code and related files.",
        message
      )
    end)

    it("should parse exception inside a stream.", function()
      local data = test_util.read_file("tests/data/bedrock_response_stream_with_exception.bin")
      local message = ""
      bedrock_provider:parse_stream_data({}, data, {
        on_chunk = function(msg) message = msg end,
      })
      assert.equals(
        "- Too many requests, please wait before trying again. You have sent too many requests.  Wait before trying again.",
        message
      )
    end)
  end)

  describe("check_curl_version_supports_aws_sig", function()
    it(
      "should return true for curl version 8.10.0",
      function()
        assert.is_true(
          bedrock_provider.check_curl_version_supports_aws_sig(
            "curl 8.10.0 (x86_64-pc-linux-gnu) libcurl/7.68.0 OpenSSL/1.1.1f zlib/1.2.11 brotli/1.0.7 libidn2/2.2.0 libpsl/0.21.0 (+libidn2/2.2.0) libssh2/1.8.0 nghttp2/1.40.0 librtmp/2.3"
          )
        )
      end
    )

    it(
      "should return true for curl version higher than 8.10.0",
      function()
        assert.is_true(
          bedrock_provider.check_curl_version_supports_aws_sig(
            "curl 8.11.0 (aarch64-apple-darwin23.6.0) libcurl/8.11.0 OpenSSL/3.4.0 (SecureTransport) zlib/1.2.12 brotli/1.1.0 zstd/1.5.6 AppleIDN libssh2/1.11.1 nghttp2/1.64.0 librtmp/2.3"
          )
        )
      end
    )

    it(
      "should return false for curl version lower than 8.10.0",
      function()
        assert.is_false(
          bedrock_provider.check_curl_version_supports_aws_sig(
            "curl 7.68.0 (x86_64-pc-linux-gnu) libcurl/7.68.0 OpenSSL/1.1.1f zlib/1.2.11 brotli/1.0.7 libidn2/2.2.0 libpsl/0.21.0 (+libidn2/2.2.0) libssh2/1.8.0 nghttp2/1.40.0 librtmp/2.3"
          )
        )
      end
    )

    it(
      "should return false for invalid version string",
      function() assert.is_false(bedrock_provider.check_curl_version_supports_aws_sig("Invalid version string")) end
    )
  end)
end)
