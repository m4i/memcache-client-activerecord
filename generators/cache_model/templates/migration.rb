class <%= migration_name %> < ActiveRecord::Migration
  def self.up
    case connection.adapter_name
    when 'MySQL'
      execute(<<-SQL)
        CREATE TABLE `<%= table_name %>` (
          `key`       VARBINARY(250) NOT NULL PRIMARY KEY,
          `value`     MEDIUMBLOB NOT NULL,
          `cas`       INT UNSIGNED NOT NULL,
          `expire_at` DATETIME
        ) ENGINE=InnoDB
      SQL

    else
      create_table :<%= table_name %>, :id => false do |t|
        t.string   :key,   :null => false, :limit => 250
        t.binary   :value, :null => false
        t.integer  :cas,   :null => false
        t.datetime :expire_at
      end
      add_index :<%= table_name %>, :key, :unique => true
    end
  end

  def self.down
    drop_table :<%= table_name %>
  end
end
