# Copyright:: (c) Autotelik Media Ltd 2010
# Author ::   Tom Statter
# Date ::     Aug 2010
# License::   MIT ?
#
# Details::   Specific over-rides/additions to support Spree Products
#
require 'spree_base_loader'
require 'spree_ecom'

module DataShift

  module SpreeEcom

    class ProductLoader < SpreeBaseLoader

      # Options
      #  
      #  :reload           : Force load of the method dictionary for object_class even if already loaded
      #  :verbose          : Verbose logging and to STDOUT
      #
      def initialize(product = nil, options = {})

        # We want the delegated methods on Variant so always include instance methods
        opts = {:find_operators => true, :instance_methods => true}.merge( options )

        # depending on version get_product_class should return us right class, namespaced or not

        super( DataShift::SpreeEcom::get_product_class, product, opts)

        raise "Failed to create Product for loading" unless @load_object
      end

      # Options:
      #   [:dummy]           : Perform a dummy run - attempt to load everything but then roll back
      #
      def perform_load( file_name, opts = {} )
        
        logger.info "Product load from File [#{file_name}]"
            
        options = opts.dup

        # In >= 1.1.0 Image moved to master Variant from Product so no association called Images on Product anymore
        
        # Non Product/database fields we can still  process
        @we_can_process_these_anyway =  ['images',  "variant_price", "variant_sku"]
          
        # In >= 1.3.0 price moved to master Variant from Product so no association called Price on Product anymore
        # taking care of it here, means users can still simply just include a price column
        @we_can_process_these_anyway << 'price' if(DataShift::SpreeEcom::version.to_f >= 1.3 )
      
        if(DataShift::SpreeEcom::version.to_f > 1 )
          options[:force_inclusion] = options[:force_inclusion] ? ([ *options[:force_inclusion]] + @we_can_process_these_anyway) : @we_can_process_these_anyway
        end

        logger.info "Product load using forced operators: [#{options[:force_inclusion]}]" if(options[:force_inclusion])
        
        super(file_name, options)
      end

      # Over ride base class process with some Spree::Product specifics
      #
      # What process a value string from a column, assigning value(s) to correct association on Product.
      # Method map represents a column from a file and it's correlated Product association.
      # Value string which may contain multiple values for a collection (has_many) association.
      #
      def process(method_detail, value)  

        raise ProductLoadError.new("Cannot process #{value} NO details found to assign to") unless(method_detail)
          
        # TODO - start supporting assigning extra data via current_attribute_hash
        current_value, current_attribute_hash = @populator.prepare_data(method_detail, value)
         
        current_method_detail = method_detail
       
        logger.debug "Processing value: [#{current_value}]"
        
        # Special cases for Products, generally where a simple one stage lookup won't suffice
        # otherwise simply use default processing from base class
        if(current_value && (current_method_detail.operator?('variants') || current_method_detail.operator?('option_types')) )

          add_options_variants

        elsif(current_method_detail.operator?('taxons') && current_value)

          add_taxons

        elsif(current_method_detail.operator?('product_properties') )

          add_properties

        elsif(current_method_detail.operator?('images') && current_value)

          add_images( load_object.master )

        elsif(current_method_detail.operator?('variant_price') && current_value)

          if(@load_object.variants.size > 0)

            if(current_value.to_s.include?(Delimiters::multi_assoc_delim))

              # Check if we processed Option Types and assign  per option
              values = current_value.to_s.split(Delimiters::multi_assoc_delim)

              if(@load_object.variants.size == values.size)
                @load_object.variants.each_with_index {|v, i| v.price = values[i].to_f }
                @load_object.save
              else
                puts "WARNING: Price entries did not match number of Variants - None Set"
              end
            end

          else
            super
          end
          
        elsif(current_method_detail.operator?('variant_sku') && current_value)

          if(@load_object.variants.size > 0)

            if(current_value.to_s.include?(Delimiters::multi_assoc_delim))

              # Check if we processed Option Types and assign  per option
              values = current_value.to_s.split(Delimiters::multi_assoc_delim)

              if(@load_object.variants.size == values.size)
                @load_object.variants.each_with_index {|v, i| v.sku = values[i].to_s }
                @load_object.save
              else
                puts "WARNING: SKU entries did not match number of Variants - None Set"
              end
            end

          else
            super
          end
          
        elsif(current_value && (current_method_detail.operator?('count_on_hand') || current_method_detail.operator?('on_hand')) )

          # Spree 2.2 - New Stock management :
          # http://guides.spreecommerce.com/developer/inventory.html
          logger.warn("Check stock settings carefully - new StockManagement in Spree >= 2.2")

          # Unless we can save here, in danger of count_on_hand getting wiped out.
          # If we set (on_hand or count_on_hand) on an unsaved object, during next subsequent save
          # looks like some validation code or something calls Variant.on_hand= with 0
          # If we save first, then our values seem to stick

          # TODO smart column ordering to ensure always valid - if we always make it very last column might not get wiped ?
          #
          save_if_new

          # Spree has some stock management stuff going on, so dont usually assign to column vut use
          # on_hand and on_hand=
          if(@load_object.variants.size > 0)

            if(current_value.to_s.include?(Delimiters::multi_assoc_delim))

              #puts "DEBUG: COUNT_ON_HAND PER VARIANT",current_value.is_a?(String),

              # Check if we processed Option Types and assign count per option
              values = current_value.to_s.split(Delimiters::multi_assoc_delim)

              if(@load_object.variants.size == values.size)
                @load_object.variants.each_with_index {|v, i| v.stock_items.first.count_on_hand = values[i].to_i }
                @load_object.save
              else
                puts "WARNING: Count on hand entries did not match number of Variants - None Set"
              end
            end

            # Can only set count on hand on Product if no Variants exist, else model throws

          elsif(@load_object.variants.size == 0)
            if(current_value.to_s.include?(Delimiters::multi_assoc_delim))
              puts "WARNING: Multiple count_on_hand values specified but no Variants/OptionTypes created"
              load_object.master.stock_items.first.count_on_hand = current_value.to_s.split(Delimiters::multi_assoc_delim).first.to_i
              #load_object.on_hand = current_value.to_s.split(Delimiters::multi_assoc_delim).first.to_i
            else
              #load_object.on_hand = current_value.to_i
              load_object.master.stock_items.first.count_on_hand = current_value.to_i
            end
          end

        else
          super
        end
      end

      private

      # Special case for OptionTypes as it's two stage process
      # First add the possible option_types to Product, then we are able
      # to define Variants on those options values.
      # So to define a Variant :
      #   1) define at least one OptionType on Product, for example Size
      #   2) Provide a value for at least one of these OptionType
      #   3) A composite Variant can be created by supplying a value for more than one OptionType
      #       fro example Colour : Red and Size Medium
      # Supported Syntax :
      #  '|' seperates Variants
      #
      #   ';' list of option values
      #  Examples : 
      #  
      #     mime_type:jpeg;print_type:black_white|mime_type:jpeg|mime_type:png, PDF;print_type:colour
      #
      def add_options_variants
      
        # TODO smart column ordering to ensure always valid by time we get to associations
        begin
          save_if_new
        rescue => e
          logger.error("Cannot add OptionTypes/Variants - Save Failed : #{e.inspect}")
          raise ProductLoadError.new("Cannot add OptionTypes/Variants - Save failed on parent Product")
        end
        # example : mime_type:jpeg;print_type:black_white|mime_type:jpeg|mime_type:png, PDF;print_type:colour

        variants = get_each_assoc

        logger.info "Adding Options Variants #{variants.inspect}"
        
        # example line becomes :  
        #   1) mime_type:jpeg|print_type:black_white  
        #   2) mime_type:jpeg  
        #   3) mime_type:png, PDF|print_type:colour

        variants.each do |per_variant|

          option_types = per_variant.split(Delimiters::multi_facet_delim)    # => [mime_type:jpeg, print_type:black_white]

          logger.info "Checking Option Types #{option_types.inspect}"
           
          optiontype_vlist_map = {}

          option_types.each do |ostr|

            oname, value_str = ostr.split(Delimiters::name_value_delim)

            option_type = @@option_type_klass.where(:name => oname).first

            unless option_type
              option_type = @@option_type_klass.create(:name => oname, :presentation => oname.humanize)
              # TODO - dynamic creation should be an option

              unless option_type
                logger.warm("WARNING: OptionType #{oname} NOT found and could not create - Not set Product")
                next
              end
              logger.info "Created missing OptionType #{option_type.inspect}"
            end
                      
            # OptionTypes must be specified first on Product to enable Variants to be created
            load_object.option_types << option_type unless load_object.option_types.include?(option_type)

            # Can be simply list of OptionTypes, some or all without values
            next unless(value_str)

            optiontype_vlist_map[option_type] ||= []

            # Now get the value(s) for the option e.g red,blue,green for OptType 'colour'
            optiontype_vlist_map[option_type] += value_str.split(',').flatten

            logger.debug("Parsed OptionValues #{optiontype_vlist_map[option_type]} for Option_Type #{option_type.name}")
          end

          next if(optiontype_vlist_map.empty?) # only option types specified - no values

          # Now create set of Variants, some of which maybe composites
          # Find the longest set of OptionValues to use as base for combining with the rest
          sorted_map = optiontype_vlist_map.sort_by { |ot, ov| ov.size }.reverse

          logger.debug("Processing Options into Variants #{sorted_map.inspect}")

          # {mime => ['pdf', 'jpeg', 'gif'], print_type => ['black_white']}
          
          lead_option_type, lead_ovalues = sorted_map.shift
          
          # TODO .. benchmarking to find most efficient way to create these but ensure Product.variants list
          # populated .. currently need to call reload to ensure this (seems reqd for Spree 1/Rails 3, wasn't required b4
          lead_ovalues.each do |ovname|

            ov_list = []

            ovname.strip!

            #TODO - not sure why I create the OptionValues here, rather than above with the OptionTypes
            ov = @@option_value_klass.where(:name => ovname, :option_type_id => lead_option_type.id).first_or_create(:presentation => ovname.humanize)
            ov_list << ov if ov
 
            # Process rest of array of types => values
            sorted_map.each do |ot, ovlist| 
              ovlist.each do |ov_for_composite|

                ov_for_composite.strip!

                # Prior Rails 4 - ov = @@option_value_klass.find_or_create_by_name_and_option_type_id(for_composite, ot.id, :presentation => for_composite.humanize)
                ov = @@option_value_klass.where(:name => ov_for_composite, :option_type_id => ot.id).first_or_create(:presentation => ov_for_composite.humanize)

                ov_list << ov if(ov)
              end
            end

            unless(ov_list.empty?)
              
              logger.info("Creating Variant from OptionValue(s) #{ov_list.collect(&:name).inspect}")
              
              i = @load_object.variants.size + 1

              variant = @load_object.variants.create( :sku => "#{load_object.sku}_#{i}", :price => load_object.price, :weight => load_object.weight, :height => load_object.height, :width => load_object.width, :depth => load_object.depth)

              variant.option_values << ov_list if(variant)    
            end
          end

          @load_object.reload unless @load_object.new_record?
          #puts "DEBUG Load Object now has Variants : #{@load_object.variants.inspect}" if(verbose)
        end

      end # each Variant

      # Special case for ProductProperties since it can have additional value applied.
      # A list of Properties with a optional Value - supplied in form :
      #   property_name:value|property_name|property_name:value
      #  Example :
      #  test_pp_002|test_pp_003:Example free value|yet_another_property

      def add_properties
        # TODO smart column ordering to ensure always valid by time we get to associations
        save_if_new

        property_list = get_each_assoc#current_value.split(Delimiters::multi_assoc_delim)

        property_list.each do |pstr|

          # Special case, we know we lookup on name so operator is effectively the name to lookup
          find_by_name, find_by_value = get_operator_and_data( pstr )

          raise "Cannot find Property via #{find_by_name} (with value #{find_by_value})" unless(find_by_name)

          property = @@property_klass.where(:name => find_by_name).first

          unless property
            property = @@property_klass.create( :name => find_by_name, :presentation => find_by_name.humanize)
            logger.info "Created New Property #{property.inspect}"
          end

          if(property)
              # Property now protected from mass assignment
              x = @@product_property_klass.new( :value => find_by_value )
              x.property = property
              x.save
              @load_object.product_properties << x
              logger.info "Created New ProductProperty #{x.inspect}"
          else
            puts "WARNING: Property #{find_by_name} NOT found - Not set Product"
          end

        end

      end

      # Nested tree structure support ..
      # TAXON FORMAT
      # name|name>child>child|name

      def add_taxons
        # TODO smart column ordering to ensure always valid by time we get to associations
        save_if_new

        chain_list = get_each_assoc  # potentially multiple chains in single column (delimited by Delimiters::multi_assoc_delim)

        chain_list.each do |chain|

          # Each chain can contain either a single Taxon, or the tree like structure parent>child>child
          name_list = chain.split(/\s*>\s*/)

          parent_name = name_list.shift

          parent_taxonomy = @@taxonomy_klass.where(:name => parent_name).first_or_create

          raise DataShift::DataProcessingError.new("Could not find or create Taxonomy #{parent_name}") unless parent_taxonomy

          parent = parent_taxonomy.root

          # Add the Taxons to Taxonomy from tree structure parent>child>child
          taxons = name_list.collect do |name|

            begin
              taxon = @@taxon_klass.where(:name => name, :parent_id => parent.id, :taxonomy_id => parent_taxonomy.id).first_or_create

              # pre Rails 4 -  taxon = @@taxon_klass.find_or_create_by_name_and_parent_id_and_taxonomy_id(name, parent && parent.id, parent_taxonomy.id)

              unless(taxon)
                logger.warn("Missing Taxon - could not find or create #{name} for parent #{parent_taxonomy.inspect}")
              end
            rescue => e
              logger.error(e.inspect)
              logger.error "Cannot assign Taxon ['#{taxon}'] to Product ['#{load_object.name}']"
              next
            end

            parent = taxon  # current taxon becomes next parent
            taxon
          end

          taxons << parent_taxonomy.root

          unique_list = taxons.compact.uniq - (@load_object.taxons || [])

          logger.debug("Product assigned to Taxons : #{unique_list.collect(&:name).inspect}")

          @load_object.taxons << unique_list unless(unique_list.empty?)
          # puts @load_object.taxons.inspect

        end

      end

    end
  end
end