# frozen_string_literal: true

# Custom shared matchers

# Negated 'change' matcher, usable also in compound expectations
# (i.e.: ".to not_change { x }.and change { y }"):
RSpec::Matchers.define_negated_matcher :not_change, :change
