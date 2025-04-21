# PDF Layout Definition Guide for goggles_admin2

This guide documents the syntax and structure of the YAML-based PDF layout definition files used in `goggles_admin2` to parse TXT files extracted from swimming results PDFs. It covers main concepts, features, and how to define and extend parsing formats.

## Overview

- **Purpose:** To convert TXT files (obtained via `pdftotext -layout`) into structured data using format definitions.
- **Location:** YAML format files reside in `app/strategies/pdf_results/formats/`.
- **Parser:** The main parser is `PdfResults::FormatParser`, using a hierarchy of definitions: `LayoutDef` → `ContextDef` → `FieldDef`.

## Main Concepts

### 1. Layout & Context
- **Layout:** Each YAML file defines a layout (format) for a specific PDF/TXT structure.
- **Context:** A context is a logical section (e.g., header, event, results) defined by a `ContextDef`. Contexts can be nested and have parent/child relationships.
- **Rows:** Each context can define rows, which are groups of fields to extract from specific lines.

### 2. Fields
- **Field:** Defined by a `FieldDef`, each field specifies how to extract a value from a line (using regex, position, or lambda).
- **Properties:**
  - `name` (required): Unique within its group.
  - `format`: Regex for extraction.
  - `lambda`: Transformation(s) to apply before matching.
  - `pop_out`: Whether to remove the matched part from the buffer.
  - `required`: If true, extraction must succeed for context to be valid.

### 3. Format Families & Subformats
- **Format Family:** Related layouts sharing a common structure (e.g., "ficr1", "ficr2").
- **Subformat:** A specialized version of a main format (e.g., `ficr1.4x050l`). Subformats inherit the main format's logic but can override or extend sections.
- **Detection:** The parser tries all known formats on each page, picking the first valid match. Multi-format documents are supported.

### 4. Parsing Flow
1. **TXT Extraction:** PDF is converted to TXT using `pdftotext -layout`.
2. **Format Detection:** `FormatParser` scans the TXT, using YAML definitions to match structure.
3. **Context Extraction:** For each page, contexts are matched and fields extracted.
4. **Data Aggregation:** Extracted data is aggregated and standardized.
5. **JSON Output:** The result is serialized as a standardized JSON file for further processing.

## YAML Format Structure Example
```yaml
ficr1:
  - name: header
    at_fixed_row: 0
    repeat: true
    rows:
      - fields:
          - name: edition
            format: "^\\s{20,}(\\d{1,2}|[IVXLCM]+)\\D?\\D?\\s+"
            required: false
          - name: meeting_name
            format: "^\\s{20,}(?>\\d{1,2}|[IVXLCM]+)?\\D?\\D?\\s+(.+)$"
      - fields:
          - name: meeting_date
            format: "[,;/\\s](?>\\d{1,2}\\s?(?>-|\\.\\.)\\s?)?(\\d{2}[\\/-\\s](?>\\d{2}|\\w{3,})[\\/-\\s](?>\\d{4}|\\d{2}))"
          - name: meeting_place
            format: "^\\s*(\\D{2,}),\\s*"
  - name: event
    ...
```

## Key Properties (ContextDef & FieldDef)
- **ContextDef:**
  - `name`: Section identifier
  - `parent`: Parent context (optional)
  - `rows`: List of row definitions (each with fields)
  - `fields`: List of fields (FieldDefs)
  - `format`: Regex to match context start
  - `repeat`: If true, context repeats (e.g., per page)
  - `at_fixed_row`: Row index to match (page-relative)
  - `row_span` / `max_row_span`: Number of lines context spans
- **FieldDef:**
  - `name`: Field name
  - `format`: Regex for value extraction
  - `lambda`: Pre-processing (method or array of methods)
  - `pop_out`: Remove matched value from buffer
  - `required`: Extraction required for context validity

## Advanced Features
- **Nested Contexts:** Contexts can be nested for hierarchical data.
- **Aliased Contexts:** Alternative context definitions for layout flexibility.
- **Repeatable Contexts:** For sections that occur multiple times (e.g., multiple events per page).
- **Custom Lambdas:** Use Ruby methods (e.g., `strip`, `split`) for preprocessing.
- **Page Handling:** Layouts are detected per page; multi-format files are parsed page-by-page.

## Example: Adding a New Format
1. Copy an existing YAML file in `formats/` as a template.
2. Adjust context and field definitions for the new layout.
3. Test parsing with `PdfController#scan` and review the output JSON.

## References
- **Core Classes:**
  - `PdfResults::FormatParser`
  - `PdfResults::LayoutDef`
  - `PdfResults::ContextDef`
  - `PdfResults::FieldDef`
- **Helpers:**
  - `parser/` directory for common field extraction logic (e.g., timing, score, city_name)
- **Docs:**
  - [`pdf_processing.md`](./pdf_processing.md)

---

This guide should help you understand, maintain, and extend the PDF layout definition system in `goggles_admin2`. For complex cases, review actual YAML files in `formats/` and the Ruby classes listed above.
