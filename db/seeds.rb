# Seed a single admin account for local development/testing.
# In production, the first admin will be created manually via the Rails console on Scalingo (one-time setup).
User.find_or_create_by!(email: "admin@sidecare.com") do |u|
  u.name = "Admin SideCare"
  u.password = "password123"
  u.password_confirmation = "password123"
  u.admin = true
  u.active = true
end
