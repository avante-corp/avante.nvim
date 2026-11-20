local stub = require("luassert.stub")
local Utils = require("avante.utils")

describe("Utils.is_text", function()
  it("accepts ASCII and well-formed UTF-8", function()
    assert.is_true(Utils.is_text(""))
    assert.is_true(Utils.is_text("plain ascii\n"))
    assert.is_true(Utils.is_text("héllo wörld — 日本語 🎉"))
  end)

  it("rejects NUL bytes", function() assert.is_false(Utils.is_text("a\0b")) end)

  it("rejects malformed UTF-8", function()
    assert.is_false(Utils.is_text("\255"))
    assert.is_false(Utils.is_text("\128 lone continuation"))
    assert.is_false(Utils.is_text("\195("))
    assert.is_false(Utils.is_text("\192\175")) -- overlong '/'
    assert.is_false(Utils.is_text("\224\128\175")) -- overlong 3-byte
    assert.is_false(Utils.is_text("\237\160\128")) -- UTF-16 surrogate
    assert.is_false(Utils.is_text("\244\144\128\128")) -- above U+10FFFF
  end)

  it("accepts a truncated trailing sequence only when asked", function()
    local cut = ("日"):sub(1, 2)
    assert.is_false(Utils.is_text("abc" .. cut))
    assert.is_true(Utils.is_text("abc" .. cut, true))
  end)
end)

describe("Utils.file_kind", function()
  local path
  before_each(function() path = vim.fn.tempname() end)
  after_each(function() vim.fn.delete(path) end)

  local function write(content)
    local file = assert(io.open(path, "wb"))
    file:write(content)
    file:close()
  end

  it("detects binary content", function()
    write("\127ELF\2\1\1\0\255")
    assert.equals("binary", Utils.file_kind(path))
  end)

  it("recognizes PDFs", function()
    write("%PDF-1.7\n\0\255")
    assert.equals("pdf", Utils.file_kind(path))
  end)

  it("treats text files as text", function()
    write("local x = 'é'\n")
    assert.equals("text", Utils.file_kind(path))
  end)

  it("recognizes images from their magic bytes, whatever the name", function()
    for _, magic in ipairs({ "\137PNG\r\n\26\n", "\255\216\255\224", "GIF89a", "RIFF\0\0\0\0WEBPVP8 " }) do
      write(magic .. "\0\255 rest")
      assert.equals("image", Utils.file_kind(path))
    end
  end)

  it("treats missing files and terminals as text, leaving errors to the reader", function()
    assert.equals("text", Utils.file_kind(path .. ".missing"))
    assert.equals("text", Utils.file_kind("term://foo"))
  end)
end)

describe("Utils.pdf_to_text", function()
  local fixture = vim.fn.tempname() .. ".pdf"
  -- A minimal valid PDF showing "Hello PDF".
  local pdf = table.concat({
    "%PDF-1.4",
    "1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj",
    "2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj",
    "3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Contents 4 0 R"
      .. " /Resources << /Font << /F1 5 0 R >> >> >> endobj",
    "4 0 obj << /Length 41 >> stream",
    "BT /F1 12 Tf 10 50 Td (Hello PDF) Tj ET",
    "endstream endobj",
    "5 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj",
    "trailer << /Root 1 0 R >>",
    "%%EOF",
  }, "\n")

  before_each(function()
    local file = assert(io.open(fixture, "wb"))
    file:write(pdf)
    file:close()
  end)
  after_each(function() vim.fn.delete(fixture) end)

  it("extracts the text when pdftotext is available", function()
    if vim.fn.executable("pdftotext") == 0 then return pending("pdftotext is not installed") end
    local text, err = Utils.pdf_to_text(fixture)
    assert.is_nil(err)
    assert.matches("Hello PDF", text, nil, true)
  end)

  it("reports a missing pdftotext", function()
    -- A path of its own: the extraction test may have cached the fixture's text.
    local uncached = vim.fn.tempname() .. ".pdf"
    vim.fn.writefile({ "%PDF-1.4" }, uncached)
    local executable = stub(vim.fn, "executable").returns(0)
    local text, err = Utils.pdf_to_text(uncached)
    executable:revert()
    vim.fn.delete(uncached)
    assert.is_nil(text)
    assert.matches("pdftotext is not installed", err, nil, true)
  end)
end)
