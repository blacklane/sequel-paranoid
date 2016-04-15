require 'sequel'

module Sequel::Plugins
  module Paranoid
    def self.configure(model, options = {})
      options = {
        :deleted_at_field_name      => :deleted_at,
        :deleted_by_field_name      => :deleted_by,
        :enable_deleted_by          => false,
        :deleted_scope_name         => :deleted,
        :non_deleted_scope_name     => :present,
        :ignore_deletion_scope_name => :with_deleted,
        :enable_default_scope       => false,
        :deleted_column_default     => nil
      }.merge(options)

      ds_mod = Module.new do
        # scope for deleted items
        define_method(options[:deleted_scope_name]) do
          send(options[:ignore_deletion_scope_name]).exclude(Sequel.qualify(model.table_name, options[:deleted_at_field_name]) => options[:deleted_column_default])
        end

        # scope for non-deleted items
        define_method(options[:non_deleted_scope_name]) do
          filter(Sequel.qualify(model.table_name, options[:deleted_at_field_name]) => options[:deleted_column_default])
        end

        # scope for both
        define_method(options[:ignore_deletion_scope_name]) do
          unfiltered
        end
      end

      im_mod = Module.new do
        #
        # Overwrite the "_destroy_delete" method which is used by sequel to
        # delete an object. This makes sure, we run all the hook correctly and
        # in a transaction.
        #
        define_method("destroy") do |*args|
          # Save the variables threadsafe (because the locks have not been
          # initialized by sequel yet).
          Thread.current["_paranoid_destroy_args_#{self.object_id}"] = args

          super(*args)
        end

        define_method("_destroy_delete") do
          # _destroy_delete does not take arguments.
          destroy_options = Thread.current["_paranoid_destroy_args_#{self.object_id}"].first
          Thread.current["_paranoid_destroy_args_#{self.object_id}"] = nil

          # set the deletion time
          self.send("#{options[:deleted_at_field_name]}=", Time.now)

          # set the deletion author
          if options[:enable_deleted_by] && destroy_options && destroy_options[:deleted_by]
            self.send("#{options[:deleted_by_field_name]}=", destroy_options[:deleted_by])
          end

          self.save
        end

        #
        # Sequel patch to allow updates to deleted instances
        # when default scope is enabled
        #

        define_method("_update_without_checking") do |columns|
          # figure out correct pk conditions (see base#this)
          conditions = this.send(:joined_dataset?) ? qualified_pk_hash : pk_hash

          # turn off with deleted, added the pk conditions back in
          update_with_deleted_dataset = this.with_deleted.where(conditions)

          # run the original update on the with_deleted dataset
          update_with_deleted_dataset.update(columns)

        end if(options[:enable_default_scope])

        #
        # Method for undeleting an instance.
        #

        define_method("recover") do
          self.send("#{options[:deleted_at_field_name]}=".to_sym, options[:deleted_column_default])

          if options[:enable_deleted_by] && self.respond_to?(options[:deleted_by_field_name].to_sym)
            self.send("#{options[:deleted_by_field_name]}=", nil)
          end

          self.save
        end

        #
        # Check if an instance is deleted.
        #

        define_method("deleted?") do
          send(options[:deleted_at_field_name]) != options[:deleted_column_default]
        end

        #
        # Enhance validates_unique to support :paranoid => true for paranoid
        # uniqueness checking.
        #
      end

      val_mod = Module.new do
        define_method("validates_unique") do |*columns|
          return super(*columns) unless columns.last.kind_of?(Hash) && columns.last.delete(:paranoid)

          if deleted?
            columns = columns.map { |c|
              case c
              when Array, Symbol
                [ c, options[:deleted_at_field_name] ].flatten
              else
                c
              end
            }

            super(*columns) { |ds|
              ds = ds.send(options[:deleted_scope_name])
              block_given? ? yield(ds) : ds
            }
          else
            super(*columns) { |ds|
              ds = ds.send(options[:non_deleted_scope_name])
              block_given? ? yield(ds) : ds
            }
          end
        end
      end

      model.instance_eval do
        #
        # Inject the scopes for the deleted and the existing entries.
        #

        dataset_module ds_mod

        #
        # Inject the instance methods defined above.
        #
        include im_mod

        #
        # Inject the validation helper defined if ValidationHelpers has already
        # been loaded.
        #

        if defined?(Sequel::Plugins::ValidationHelpers) &&
            plugins.include?(Sequel::Plugins::ValidationHelpers)
          include val_mod
        end

        #
        # Inject the default scope that filters deleted entries.
        #

        if options[:enable_default_scope]
          set_dataset(self.send(options[:non_deleted_scope_name]))
        end
      end
    end
  end
end
