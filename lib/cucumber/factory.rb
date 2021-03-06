require 'cucumber/factory/build_strategy'

module Cucumber
  class Factory
    class Error < StandardError; end

    ATTRIBUTES_PATTERN = '( with the .+?)?( (?:which|who|that) is .+?)?'
    TEXT_ATTRIBUTES_PATTERN = ' (?:with|and) these attributes:'

    RECORD_PATTERN = 'there is an? (.+?)( \(.+?\))?'
    NAMED_RECORD_PATTERN = '"([^\"]*)" is an? (.+?)( \(.+?\))?'

    NAMED_RECORDS_VARIABLE = :'@named_cucumber_factory_records'

    VALUE_INTEGER = /\d+/
    VALUE_DECIMAL = /[\d\.]+/
    VALUE_STRING = /"[^"]*"/
    VALUE_ARRAY = /\[[^\]]*\]/
    VALUE_LAST_RECORD = /\babove\b/

    VALUE_SCALAR = /#{VALUE_STRING}|#{VALUE_DECIMAL}|#{VALUE_INTEGER}/

    CLEAR_NAMED_RECORDS_STEP_DESCRIPTOR = {
      :kind => :Before,
      :block => proc { Cucumber::Factory.send(:reset_named_records, self) }
    }

    # We cannot use vararg blocks in the descriptors in Ruby 1.8, as explained by
    # Aslak: http://www.ruby-forum.com/topic/182927. We use different descriptors and cucumber priority to work around
    # it.

    NAMED_CREATION_STEP_DESCRIPTOR = {
      :kind => :Given,
      :pattern => /^#{NAMED_RECORD_PATTERN}#{ATTRIBUTES_PATTERN}?$/,
      :block => lambda { |a1, a2, a3, a4, a5| Cucumber::Factory.send(:parse_named_creation, self, a1, a2, a3, a4, a5) }
    }

    CREATION_STEP_DESCRIPTOR = {
      :kind => :Given,
      :pattern => /^#{RECORD_PATTERN}#{ATTRIBUTES_PATTERN}$/,
      :block => lambda { |a1, a2, a3, a4| Cucumber::Factory.send(:parse_creation, self, a1, a2, a3, a4) }
    }

    NAMED_CREATION_STEP_DESCRIPTOR_WITH_TEXT_ATTRIBUTES = {
      :kind => :Given,
      :pattern => /^"#{NAMED_RECORD_PATTERN}#{ATTRIBUTES_PATTERN}#{TEXT_ATTRIBUTES_PATTERN}?$/,
      :block => lambda { |a1, a2, a3, a4, a5, a6| Cucumber::Factory.send(:parse_named_creation, self, a1, a2, a3, a4, a5, a6) },
      :priority => true
    }

    CREATION_STEP_DESCRIPTOR_WITH_TEXT_ATTRIBUTES = {
      :kind => :Given,
      :pattern => /^#{RECORD_PATTERN}#{ATTRIBUTES_PATTERN}#{TEXT_ATTRIBUTES_PATTERN}$/,
      :block => lambda { |a1, a2, a3, a4, a5| Cucumber::Factory.send(:parse_creation, self, a1, a2, a3, a4, a5) },
      :priority => true
    }

    class << self

      def add_steps(main)
        add_step(main, CREATION_STEP_DESCRIPTOR)
        add_step(main, NAMED_CREATION_STEP_DESCRIPTOR)
        add_step(main, CREATION_STEP_DESCRIPTOR_WITH_TEXT_ATTRIBUTES)
        add_step(main, NAMED_CREATION_STEP_DESCRIPTOR_WITH_TEXT_ATTRIBUTES)
        add_step(main, CLEAR_NAMED_RECORDS_STEP_DESCRIPTOR)
      end

      private

      def add_step(main, descriptor)
        main.instance_eval {
          kind = descriptor[:kind]
          object = send(kind, *[descriptor[:pattern]].compact, &descriptor[:block])
          object.overridable(:priority => descriptor[:priority] ? 1 : 0) if kind != :Before
          object
        }
      end

      def reset_named_records(world)
        world.instance_variable_set(NAMED_RECORDS_VARIABLE, {})
      end

      def named_records(world)
        hash = world.instance_variable_get(NAMED_RECORDS_VARIABLE)
        hash || reset_named_records(world)
      end

      def get_named_record(world, name)
        named_records(world)[name].tap do |record|
          record.reload if record.respond_to?(:reload) and record.respond_to?(:new_record?) and not record.new_record?
        end
      end

      def set_named_record(world, name, record)
        named_records(world)[name] = record
      end
  
      def parse_named_creation(world, name, raw_model, raw_variant, raw_attributes, raw_boolean_attributes, raw_multiline_attributes = nil)
        record = parse_creation(world, raw_model, raw_variant, raw_attributes, raw_boolean_attributes, raw_multiline_attributes)
        set_named_record(world, name, record)
      end
    
      def parse_creation(world, raw_model, raw_variant, raw_attributes, raw_boolean_attributes, raw_multiline_attributes = nil)
        build_strategy = BuildStrategy.from_prose(raw_model, raw_variant)
        model_class = build_strategy.model_class
        attributes = {}
        if raw_attributes.try(:strip).present?
          raw_attributes.scan(/(?:the |and |with |but |,| )+(.*?) (#{VALUE_SCALAR}|#{VALUE_ARRAY}|#{VALUE_LAST_RECORD})/).each do |fragment|
            attribute = attribute_name_from_prose(fragment[0])
            value = fragment[1]
            attributes[attribute] = attribute_value(world, model_class, attribute, value)
          end
        end
        if raw_boolean_attributes.try(:strip).present?
          raw_boolean_attributes.scan(/(?:which|who|that|is| )*(not )?(.+?)(?: and | but |,|$)+/).each do |fragment|
            flag = !fragment[0] # if the word 'not' didn't match above, this expression is true
            attribute = attribute_name_from_prose(fragment[1])
            attributes[attribute] = flag
          end
        end
        if raw_multiline_attributes.present?
          # DocString e.g. "first name: Jane\nlast name: Jenny\n"
          if raw_multiline_attributes.is_a?(String)
            raw_multiline_attributes.split("\n").each do |fragment|
              raw_attribute, value = fragment.split(': ')
              attribute = attribute_name_from_prose(raw_attribute)
              attributes[attribute] = value
            end
          # DataTable e.g. in raw [["first name", "Jane"], ["last name", "Jenny"]]
          else
            raw_multiline_attributes.raw.each do |raw_attribute, value|
              attribute = attribute_name_from_prose(raw_attribute)
              attributes[attribute] = value
            end
          end
        end
        record = build_strategy.create_record(attributes)
        remember_record_names(world, record, attributes)
        record
      end

      def attribute_value(world, model_class, attribute, value)
        association = model_class.respond_to?(:reflect_on_association) ? model_class.reflect_on_association(attribute) : nil

        if matches_fully?(value, VALUE_ARRAY)
          elements_str = unquote(value)
          value = elements_str.scan(VALUE_SCALAR).map { |v| attribute_value(world, model_class, attribute, v) }
        elsif association.present?
          if matches_fully?(value, VALUE_LAST_RECORD)
            value = CucumberFactory::Switcher.find_last(association.klass) or raise Error, "There is no last #{attribute}"
          elsif matches_fully?(value, VALUE_STRING)
            value = unquote(value)
            value = get_named_record(world, value) || transform_value(world, value)
          elsif matches_fully?(value, VALUE_INTEGER)
            value = value.to_s
            value = get_named_record(world, value) || transform_value(world, value)
          else
            raise Error, "Cannot set association #{model_class}##{attribute} to #{value}."
          end
        else
          value = resolve_scalar_value(world, model_class, attribute, value)
        end
        value
      end

      def resolve_scalar_value(world, model_class, attribute, value)
        if matches_fully?(value, VALUE_STRING)
          value = unquote(value)
          value = transform_value(world, value)
        elsif matches_fully?(value, VALUE_INTEGER)
          value = value.to_i
        elsif matches_fully?(value, VALUE_DECIMAL)
          value = BigDecimal(value)
        else
          raise Error, "Cannot set attribute #{model_class}##{attribute} to #{value}."
        end
        value
      end

      def unquote(string)
        string[1, string.length - 2]
      end

      def full_regexp(partial_regexp)
        Regexp.new("\\A" + partial_regexp.source + "\\z", partial_regexp.options)
      end

      def matches_fully?(string, partial_regexp)
        string =~ full_regexp(partial_regexp)
      end

      def transform_value(world, value)
        # Transforms were a feature available in Cucumber 1 and 2.
        # They have been kind-of replaced by ParameterTypes, which don't work with generic steps
        # like CucumberFactory's.
        # https://app.cucumber.pro/projects/cucumber-ruby/documents/branch/master/features/docs/writing_support_code/parameter_types.feature
        if world.respond_to?(:Transform)
          world.Transform(value)
        else
          value
        end
      end

      def attribute_name_from_prose(prose)
        prose.downcase.gsub(" ", "_").to_sym
      end

      def remember_record_names(world, record, attributes)
        rememberable_values = attributes.values.select { |v| v.is_a?(String) || v.is_a?(Fixnum) }
        for value in rememberable_values
          set_named_record(world, value.to_s, record)
        end
      end

    end
  end
end
