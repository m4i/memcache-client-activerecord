# based on railties/lib/rails_generator/generators/components/model/model_generator.rb
class CacheModelGenerator < Rails::Generator::NamedBase
  default_options :skip_migration => false

  def manifest
    record do |m|
      # Check for class naming collisions.
      m.class_collisions class_name

      # Model directory.
      m.directory File.join('app/models', class_path)

      # Model class.
      m.template 'model.rb', File.join('app/models', class_path, "#{file_name}.rb")

      # Migration.
      migration_file_path = file_path.gsub(/\//, '_')
      migration_name = class_name
      if ActiveRecord::Base.pluralize_table_names
        migration_name = migration_name.pluralize
        migration_file_path = migration_file_path.pluralize
      end

      unless options[:skip_migration]
        m.migration_template 'migration.rb', 'db/migrate', :assigns => {
          :migration_name => "Create#{migration_name.gsub(/::/, '')}"
        }, :migration_file_name => "create_#{migration_file_path}"
      end
    end
  end

  protected
    def add_options!(opt)
      opt.separator ''
      opt.separator 'Options:'
      opt.on('--skip-migration',
             "Don't generate a migration file for this model") do |value|
        options[:skip_migration] = value
      end
    end
end
