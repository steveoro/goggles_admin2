# Goggles Admin2 main TO-DOs

[x] = DONE, [ ] = TODO, [~] = almost ok, additional testing needed

- [ ] 

---8<---
[Data Import question]
We need to create a one-shot ruby script that will process this <file@mst_ita_singapore_2025.txt>, filling @mst_ita_singapore_2025.json, which is a "LayoutType 2" standard goggles datafile for results of a Meeting. For more reference, see @DATA_STRUCTURES.md#L139-268 .
The structure of the source text file seems constant enough to be parsed with a loop, albeit the overall layout is misaligned when compared with the source PDF file from which it was extracted: @mst_ita_singapore_2025.pdf .

# Data that needs to be extracted

First, section "title". For example @mst_ita_singapore_2025.txt#L7-8 @mst_ita_singapore_2025.txt#L49-50 @mst_ita_singapore_2025.txt#L100-101 @mst_ita_singapore_2025.txt#L137-138 @mst_ita_singapore_2025.txt#L171-172 are all start of a new section that can be added to @mst_ita_singapore_2025.json#L18-27 with a different "title". This @mst_ita_singapore_2025.txt#L187-188 , for example, is a follow-up of the previous section (same title) on page change.
By checking the original PDF, we can see that some section titles like @mst_ita_singapore_2025.txt#L6-8 are misaligned by the conversion from PDF to text: "50m Freestyle" clearly applies also to the first row @mst_ita_singapore_2025.txt#L5-6 as we can see from the table separators in the PDF files.
On each page change usually the document title (@mst_ita_singapore_2025.txt#L188-190  @mst_ita_singapore_2025.txt#L1-3 ) and the headers (@mst_ita_singapore_2025.txt#L190-192 <or@mst_ita_singapore_2025.txt>#L3-5 ) are repeated.
The first line of the header seems always to be the current gender type of the results (@mst_ita_singapore_2025.txt#L3-4 : "UOMINI"="Males" -> "fin_sesso": "M";@mst_ita_singapore_2025.txt#L458-459 : "DONNE"="Females" -> "fin_sesso": "F")

The category code, "fin_sigla_categoria", for <example@mst_ita_singapore_2025.txt>#L9 ("M25") @mst_ita_singapore_2025.txt#L15 ("M30")  or @mst_ita_singapore_2025.txt#L20 ("M35") is slightly misaligned too when compared to the table separators in the PDF file.
For example, @mst_ita_singapore_2025.txt#L20 as a category code actually starts the line above @mst_ita_singapore_2025.txt#L19-20.

The ranking position "pos" (@DATA_STRUCTURES.md#L164-165 ), the athlete "name" (@DATA_STRUCTURES.md#L165-166 ), the "team" name (@DATA_STRUCTURES.md#L167-168 ), the "timing" result (@DATA_STRUCTURES.md#L168-169 ) and the scoring "std_score" (@DATA_STRUCTURES.md#L169-170 ) seem to be *almost* always on the same row, albeit with different spacing from page to page. For example:

## Individual results, categpry code ("fin_sigla_categoria")

Not always aligned with the actual start of the section (see PDF), relatively easy to spot because it's at the start of a line; for example: @mst_ita_singapore_2025.txt#L775 @mst_ita_singapore_2025.txt#L777 @mst_ita_singapore_2025.txt#L549 @mst_ita_singapore_2025.txt#L415

## Ind. results, ranking position ("pos")

Usually it's a 1..3 digit number, but it can be also "NT" ("no time") or "DNS" (disqualify). For example: @mst_ita_singapore_2025.txt#L5 (rank 33), @mst_ita_singapore_2025.txt#L18 (rank 114) @mst_ita_singapore_2025.txt#L19 (rank 2) @mst_ita_singapore_2025.txt#L40 (DNS)
@mst_ita_singapore_2025.txt#L70 (NT)
In some cases, the conversion messed this part of the layout too. For example: these 2 rows @mst_ita_singapore_2025.txt#L74-77 are both supposed to be "NT", but the code is not repeated for each line, but the actual table separator can be seen by checking the original PDF file.

## Ind. results, "name"

Examples: @mst_ita_singapore_2025.txt#L58 @mst_ita_singapore_2025.txt#L5 @mst_ita_singapore_2025.txt#L21 @mst_ita_singapore_2025.txt#L76 @mst_ita_singapore_2025.txt#L74

## Ind. results, "team"

Examples: @mst_ita_singapore_2025.txt#L5 @mst_ita_singapore_2025.txt#L12 @mst_ita_singapore_2025.txt#L27

## Ind. results "timing"

We can have "NT" and "DNS" here too, but usually has a format like this @mst_ita_singapore_2025.txt#L5  (seconds.hundredths) or this @mst_ita_singapore_2025.txt#L60 (minutes:seconds.hundredths).
More examples: @mst_ita_singapore_2025.txt#L69 @mst_ita_singapore_2025.txt#L68 @mst_ita_singapore_2025.txt#L70 @mst_ita_singapore_2025.txt#L80

## Ind. results, "std_score"

Either missing, for DNS and NT rows, or 3-4 numeric digits almost at the end of the line: @mst_ita_singapore_2025.txt#L176 @mst_ita_singapore_2025.txt#L192 @mst_ita_singapore_2025.txt#L199
@mst_ita_singapore_2025.txt#L200
When the line ends with a "RI" as in @mst_ita_singapore_2025.txt#L259 or @mst_ita_singapore_2025.txt#L271  or @mst_ita_singapore_2025.txt#L273 , it means that is an Italian Record (but we don't store that information on the target JSON file)

## Relay results

Since it's only 1 page,this can be defined more easily as seen on the PDF file:
" title": "4x50m Freestyle" is this area: @mst_ita_singapore_2025.txt#L836-884
" title": "4x50m Medley" is the rest of the page: @mst_ita_singapore_2025.txt#L884-936
Unfortunately, al fields are somehow vertically centered so it's difficult to attribute the correct value to the correct area.

For each  relay result usually there is:

1. a "team" name, on first row, examples:@mst_ita_singapore_2025.txt#L836 @mst_ita_singapore_2025.txt#L839 @mst_ita_singapore_2025.txt#L842 @mst_ita_singapore_2025.txt#L847 @mst_ita_singapore_2025.txt#L851

2. gender code, for example: @mst_ita_singapore_2025.txt#L837 @mst_ita_singapore_2025.txt#L846 @mst_ita_singapore_2025.txt#L850 @mst_ita_singapore_2025.txt#L862 @mst_ita_singapore_2025.txt#L866
@mst_ita_singapore_2025.txt#L869
Here "W" should become "F" (field "fin_sesso" in the target JSON file) but both "M" and "X" are ok as values for the target field (@DATA_STRUCTURES.md#L204-205 ).

3. category code (@DATA_STRUCTURES.md#L203-204 )
For relays, the "fin_sigla_categoria" code can be extracted as is and has the fixed format "NNN-NNN". For example: @mst_ita_singapore_2025.txt#L837 @mst_ita_singapore_2025.txt#L840 @mst_ita_singapore_2025.txt#L843

4. ranking ("pos": @DATA_STRUCTURES.md#L207-209 )
Always beside the catgory code, integer 1..2, it can also be a "DNS"": @mst_ita_singapore_2025.txt#L837 @mst_ita_singapore_2025.txt#L840 @mst_ita_singapore_2025.txt#L872

5. relay swimmers, in between brackets
4 relay swimmer names, separated by ";", in between round braces: @mst_ita_singapore_2025.txt#L838 @mst_ita_singapore_2025.txt#L841 @mst_ita_singapore_2025.txt#L844
@mst_ita_singapore_2025.txt#L860
The 4 relay swimmers in the text file do not show year of birth or gender, but the gender of the section can be used to set a fixed value if it's either "M" or "F" ("W"); the target fields are: @DATA_STRUCTURES.md#L211-212 @DATA_STRUCTURES.md#L214-215 @DATA_STRUCTURES.md#L217-218 @DATA_STRUCTURES.md#L220-221 ; gender type for each swimmer follows the same numbering.

6. relay timing (@DATA_STRUCTURES.md#L210-211 )
Example: @mst_ita_singapore_2025.txt#L837 @mst_ita_singapore_2025.txt#L840 @mst_ita_singapore_2025.txt#L859 @mst_ita_singapore_2025.txt#L872 @mst_ita_singapore_2025.txt#L895

In one case the section title breaks the layout (@mst_ita_singapore_2025.txt#L854-859 ) and splits a single relay result in two.

Analyze the structure and plan for the best course of action.
