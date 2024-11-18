# frozen_string_literal: true

# Decorator for Hash objects to produce HTML labels.
# Assumes the decorated hash as at least an 'id' and an 'updated_at' keys.
class HashRowDecorator < Draper::Decorator
  delegate_all

  # Returns a formatted HTML label for the 'id' value of the object.
  def id_label
    h.tag.small('ID: ') << h.tag.code(object['id'])
  end

  # Returns a formatted HTML label for the 'updated_at' value of the object.
  def updated_at
    time_str = object.fetch('updated_at', '').to_s.split('.000Z').first.tr('T', ' ')
    h.tag.small(h.tag.i("(#{time_str})"))
  end

  # Returns a formatted HTML label for the specified +field_name+ value of the object.
  def label_for(field_name)
    h.tag.span do
      h.tag.small(class: 'text-secondary') do
        "#{field_name}: ".html_safe << h.tag.b(object[field_name]) # rubocop:disable Rails/OutputSafety
      end
    end
  end

  # Returns a formatted HTML label for this decorated object instance.
  def html_row
    field_name_remainder = object.keys.delete_if { |k| %w[id updated_at].include?(k) }
    result = id_label
    field_name_remainder.each do |field_name|
      result << ", #{label_for(field_name)}".html_safe # rubocop:disable Rails/OutputSafety
    end
    result << "&nbsp;#{updated_at}".html_safe # rubocop:disable Rails/OutputSafety
    h.tag.span(result)
  end
end
