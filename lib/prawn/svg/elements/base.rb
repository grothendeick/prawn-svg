class Prawn::SVG::Elements::Base
  extend Forwardable

  include Prawn::SVG::Attributes::Transform
  include Prawn::SVG::Attributes::Opacity
  include Prawn::SVG::Attributes::ClipPath
  include Prawn::SVG::Attributes::Stroke

  PAINT_TYPES = %w(fill stroke)
  COMMA_WSP_REGEXP = Prawn::SVG::Elements::COMMA_WSP_REGEXP

  SkipElementQuietly = Class.new(StandardError)
  SkipElementError = Class.new(StandardError)
  MissingAttributesError = Class.new(SkipElementError)

  attr_reader :document, :source, :parent_calls, :base_calls, :state, :attributes, :properties
  attr_accessor :calls

  def_delegators :@document, :x, :y, :distance, :points, :warnings
  def_delegator :@state, :computed_properties

  def initialize(document, source, parent_calls, state)
    @document = document
    @source = source
    @parent_calls = parent_calls
    @state = state
    @base_calls = @calls = []

    if id = source.attributes["id"]
      document.elements_by_id[id] = self
    end
  end

  def process
    extract_attributes_and_properties
    parse_and_apply
  end

  def parse_and_apply
    parse

    apply_calls_from_standard_attributes
    apply

    process_child_elements if container?

    append_calls_to_parent unless computed_properties.display == 'none'
  rescue SkipElementQuietly
  rescue SkipElementError => e
    @document.warnings << e.message
  end

  def name
    @name ||= source.name
  end

  protected

  def parse
  end

  def apply
  end

  def bounding_box
  end

  def container?
    false
  end

  def add_call(name, *arguments)
    @calls << [name.to_s, arguments, []]
  end

  def add_call_and_enter(name, *arguments)
    @calls << [name.to_s, arguments, []]
    @calls = @calls.last.last
  end

  def append_calls_to_parent
    @parent_calls.concat(@base_calls)
  end

  def add_calls_from_element(other)
    @calls.concat other.base_calls
  end

  def new_call_context_from_base
    old_calls = @calls
    @calls = @base_calls
    yield
    @calls = old_calls
  end

  def process_child_elements(xml_elements: source.elements, base_state: state)
    xml_elements.each do |elem|
      if element_class = Prawn::SVG::Elements::TAG_CLASS_MAPPING[elem.name.to_sym]
        add_call "save"

        child = element_class.new(@document, elem, @calls, base_state.dup)
        child.process

        add_call "restore"
      else
        @document.warnings << "Unknown tag '#{elem.name}'; ignoring"
      end
    end
  end

  def apply_calls_from_standard_attributes
    parse_transform_attribute_and_call
    parse_opacity_attributes_and_call
    parse_clip_path_attribute_and_call
    apply_colors
    parse_stroke_attributes_and_call
    apply_drawing_call
  end

  def apply_drawing_call
    if !state.disable_drawing && !container?
      draw_types = PAINT_TYPES.select { |property| computed_properties.send(property) != 'none' }

      if draw_types.empty?
        add_call_and_enter("end_path")
      else
        add_call_and_enter(draw_types.join("_and_"))
      end
    end
  end

  def apply_colors
    PAINT_TYPES.each do |type|
      color = properties.send(type)

      next if [nil, 'inherit', 'none'].include?(color)

      if color == 'currentColor'
        color = computed_properties.color
      end

      results = Prawn::SVG::Color.parse(color, document.gradients)

      success = results.detect do |result|
        case result
        when Prawn::SVG::Color::Hex
          add_call "#{type}_color", result.value
          true
        when Prawn::SVG::Elements::Gradient
          arguments = result.gradient_arguments(self)
          if arguments
            add_call "#{type}_gradient", **arguments
            true
          end
        end
      end

      # If we were unable to find a suitable color candidate,
      # we turn off this type of paint.
      if success.nil?
        computed_properties.set(type, 'none')
      end
    end
  end

  def clamp(value, min_value, max_value)
    [[value, min_value].max, max_value].min
  end

  def extract_attributes_and_properties
    if @document && @document.css_parser
      tag_style = @document.css_parser.find_by_selector(source.name)
      id_style = @document.css_parser.find_by_selector("##{source.attributes["id"]}") if source.attributes["id"]

      if classes = source.attributes["class"]
        class_styles = classes.strip.split(/\s+/).collect do |class_name|
          @document.css_parser.find_by_selector(".#{class_name}")
        end
      end

      element_style = source.attributes['style']

      style = [tag_style, class_styles, id_style, element_style].flatten.collect do |s|
        s.nil? || s.strip == "" ? "" : "#{s}#{";" unless s.match(/;\s*\z/)}"
      end.join
    else
      style = source.attributes['style'] || ""
    end

    @attributes = {}
    @properties = Prawn::SVG::Properties.new

    source.attributes.each do |name, value|
      # Properties#set returns nil if it's not a recognised property name
      @properties.set(name, value) or @attributes[name] = value
    end

    @properties.load_hash(parse_css_declarations(style))

    state.computed_properties.compute_properties(@properties)
  end

  def parse_css_declarations(declarations)
    # copied from css_parser
    declarations.gsub!(/(^[\s]*)|([\s]*$)/, '')

    output = {}
    declarations.split(/[\;$]+/m).each do |decs|
      if matches = decs.match(/\s*(.[^:]*)\s*\:\s*(.[^;]*)\s*(;|\Z)/i)
        property, value, _ = matches.captures
        output[property.downcase] = value
      end
    end
    output
  end

  def require_attributes(*names)
    missing_attrs = names - attributes.keys
    if missing_attrs.any?
      raise MissingAttributesError, "Must have attributes #{missing_attrs.join(", ")} on tag #{name}; skipping tag"
    end
  end

  def require_positive_value(*args)
    if args.any? {|arg| arg.nil? || arg <= 0}
      raise SkipElementError, "Invalid attributes on tag #{name}; skipping tag"
    end
  end

  def extract_element_from_url_id_reference(value, expected_type = nil)
    matches = value.strip.match(/\Aurl\(\s*#(\S+)\s*\)\z/i) if value
    element = document.elements_by_id[matches[1]] if matches
    element if element && (expected_type.nil? || element.name == expected_type)
  end
end
