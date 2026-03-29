class EnableUuidV7Support < ActiveRecord::Migration[8.1]
  def up
    enable_extension "pgcrypto" unless extension_enabled?("pgcrypto")

    safety_assured do
      execute <<~SQL
        CREATE OR REPLACE FUNCTION gen_random_uuid_v7()
        RETURNS uuid
        LANGUAGE plpgsql
        AS $$
        DECLARE
          timestamp_ms bigint;
          value bytea;
          encoded text;
        BEGIN
          timestamp_ms := floor(extract(epoch FROM clock_timestamp()) * 1000);
          value := gen_random_bytes(16);

          value := set_byte(value, 0, ((timestamp_ms >> 40) & 255)::integer);
          value := set_byte(value, 1, ((timestamp_ms >> 32) & 255)::integer);
          value := set_byte(value, 2, ((timestamp_ms >> 24) & 255)::integer);
          value := set_byte(value, 3, ((timestamp_ms >> 16) & 255)::integer);
          value := set_byte(value, 4, ((timestamp_ms >> 8) & 255)::integer);
          value := set_byte(value, 5, (timestamp_ms & 255)::integer);

          value := set_byte(value, 6, ((get_byte(value, 6) & 15) | 112)::integer);
          value := set_byte(value, 8, ((get_byte(value, 8) & 63) | 128)::integer);

          encoded := encode(value, 'hex');

          RETURN (
            substr(encoded, 1, 8) || '-' ||
            substr(encoded, 9, 4) || '-' ||
            substr(encoded, 13, 4) || '-' ||
            substr(encoded, 17, 4) || '-' ||
            substr(encoded, 21, 12)
          )::uuid;
        END;
        $$;
      SQL
    end
  end

  def down
    safety_assured do
      execute "DROP FUNCTION IF EXISTS gen_random_uuid_v7()"
    end
  end
end
