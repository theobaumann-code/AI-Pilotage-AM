# Seed a single admin account for local development/testing.
# In production, the first admin will be created manually via the Rails console on Scalingo (one-time setup).
User.find_or_create_by!(email: "admin@sidecare.com") do |u|
  u.name = "Admin SideCare"
  u.admin = true
  u.active = true
end

User.find_or_create_by!(email: "am@sidecare.com") do |u|
  u.name = "AM Test"
  u.admin = false
  u.active = true
end
