class EnablePgvector < ActiveRecord::Migration[8.1]
  def up
    safety_assured { enable_extension "vector" }
  end

  def down
    safety_assured { disable_extension "vector" }
  end
end
