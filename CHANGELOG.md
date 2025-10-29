## 2025-10-29 — Bookings & Session Auth Stable
- Session login (/auth/login) verified OK
- Lessons list (/lessons) verified OK
- My bookings (/bookings/me) verified OK
- Create booking (POST /lessons/:id/book) returns 201
- Cancel (DELETE /bookings/:id) & Restore (POST /bookings/:id/restore) return 204
- Capacity reflects booking/restoration (manual DB reset used during test)

### Follow-ups
- Capacity/stats: exclude soft-deleted bookings from counts
- Admin cancellation endpoint (e.g., POST /admin/lessons/:lessonID/bookings/:bookingID/cancel)
- Optional: date-range filters for lessons/bookings
