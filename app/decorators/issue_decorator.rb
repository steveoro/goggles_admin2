# frozen_string_literal: true

# = IssueDecorator
#
class IssueDecorator < Draper::Decorator
  delegate_all

  # Returns the HTML icon associated with the current status value with a verbose description underneath.
  def status_icon_with_label
    h.tag.span do
      decorated.state_flag << '<br/>'.html_safe <<
        h.tag.small(class: 'text-secondary') do
          h.tag.pre do
            I18n.t("issues.status_#{object.status}").html_safe
          end
        end
    end
  end

  # Returns the #created_at value formatted for a narrow column size.
  def narrow_created_at
    "#{object.created_at&.strftime('%d %B')}<br/>#{object.created_at&.strftime('%H:%M')}".html_safe
  end

  # Returns a formatted (key,value) map for the #req, if the type
  # of issue allows it
  def html_title
    decorated.code_flag <<
      "&nbsp;#{object.code}&nbsp;-&nbsp;".html_safe <<
      decorated.long_label << h.tag.br <<
      h.tag.small do
        h.tag.code(class: 'text-secondary') { formatted_request }
      end
  end

  # Returns a formatted (key,value) map for the #req, if the type
  # of issue allows it
  def formatted_request
    # No particular format needed for anything except generic bugs:
    return object.req if object.code != '4'

    # Prepare a bullet list with all the fields:
    parsed_keymap = JSON.parse(object.req).map { |k, v| h.tag.li("#{k.upcase}: #{v}") }
    h.tag.ul(parsed_keymap.join("\r\n").html_safe)
  end

  # Returns the decorated base object instance, memoized.
  def decorated
    @decorated ||= object.decorate
  end
end
