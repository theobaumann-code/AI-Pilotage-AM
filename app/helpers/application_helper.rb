module ApplicationHelper
  # Sensitive inline-edit fields (contract ARR, external ID…) start locked (grayed, read-only) so a stray
  # click, scroll-wheel-over-number-input, or drag can't silently change them — a click unlocks the field,
  # and the actual change still requires confirming, with an easy revert on cancel.
  def locked_field_attrs(confirm_message)
    {
      class: "field-locked",
      readonly: true,
      onclick: "if(this.readOnly){this.readOnly=false;this.classList.remove('field-locked');this.select&&this.select();}",
      onchange: "if(confirm(#{confirm_message.to_json})){this.form.requestSubmit();}else{this.value=this.defaultValue;this.readOnly=true;this.classList.add('field-locked');}"
    }
  end
end
