# frozen_string_literal: true

module Shell
  #
  # = Shell::PaletteTriggerComponent
  #
  # The top bar button opening the command palette (Shell::PaletteComponent, also Ctrl+K / Cmd+K): rendered in the
  # +search+ slot of Shell::TopBarComponent by the application layout. Icon only under 1600px (like the status pill
  # labels: the seven pills must fit next to it), plus its label and the shortcut above; it never shrinks.
  #
  class PaletteTriggerComponent < ViewComponent::Base
    protected

    def button_attributes
      {
        type: 'button', id: 'palette-trigger', class: 'btn btn-sm btn-outline-secondary d-inline-flex align-items-center gap-2',
        title: t('shell.palette.trigger_title'), 'aria-label' => t('shell.palette.trigger_title'),
        'aria-haspopup' => 'dialog', 'aria-keyshortcuts' => 'Control+K Meta+K',
        data: { bs_toggle: 'modal', bs_target: "##{Shell::PaletteComponent::DOM_ID}" }
      }
    end
  end
end
