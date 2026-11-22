# frozen_string_literal: true

module Rbjq
  # Bessel functions of the first and second kind (j0, j1, jn, y0, y1, yn).
  # Ruby's Math module does not provide them.
  #
  # J_n uses Bessel's integral, which the trapezoidal rule evaluates to
  # machine precision because the integrand is periodic. Y_0 and Y_1 use
  # their power series (summed exactly with Rational) for moderate x and the
  # asymptotic expansion for large x; Y_n uses the forward recurrence.
  module Bessel
    module_function

    EULER = 0.5772156649015329

    def jn(n, x)
      x = x.to_f
      return Float::NAN if x.nan?
      return 0.0 if x.infinite?

      n = n.to_i
      return (n.even? ? 1 : -1) * jn(-n, x) if n.negative?
      return (n.even? ? 1 : -1) * jn(n, -x) if x.negative?
      return (n.zero? ? 1.0 : 0.0) if x.zero?

      return asymptotic_j(n, x) if x > 50 && x > n * n

      # J_n(x) = 1/pi * integral_0^pi cos(n t - x sin t) dt
      m = (x + n).ceil + 40
      h = Math::PI / m
      sum = 0.5 * (1.0 + Math.cos(n * Math::PI))
      (1...m).each { |i| sum += Math.cos((n * i * h) - (x * Math.sin(i * h))) }
      sum * h / Math::PI
    end

    def yn(n, x)
      x = x.to_f
      return Float::NAN if x.nan? || x.negative?
      return -Float::INFINITY if x.zero?
      return 0.0 if x.infinite?

      n = n.to_i
      return (n.even? ? 1 : -1) * yn(-n, x) if n.negative?
      return y0(x) if n.zero?
      return y1(x) if n == 1

      a = y0(x)
      b = y1(x)
      (1...n).each do |k|
        a, b = b, ((2.0 * k / x) * b) - a
        break if b.infinite?
      end
      b
    end

    def y0(x)
      x = x.to_f
      return Float::NAN if x.nan? || x.negative?
      return -Float::INFINITY if x.zero?
      return asymptotic_y(0, x) if x > 30

      # Y0 = 2/pi (ln(x/2) + gamma) J0 + 2/pi * sum_{k>=1} (-1)^(k+1) H_k (x^2/4)^k / (k!)^2
      q = (Rational(x)**2) / 4
      term = Rational(1)
      harmonic = Rational(0)
      sum = Rational(0)
      k = 0
      loop do
        k += 1
        term = term * q / (k * k)
        harmonic += Rational(1, k)
        t = term * harmonic
        sum += k.odd? ? t : -t
        break if k > 5 && t.abs < sum.abs * Rational(1, 10**20)
      end
      2.0 / Math::PI * (((Math.log(x / 2) + EULER) * jn(0, x)) + sum.to_f)
    end

    def y1(x)
      x = x.to_f
      return Float::NAN if x.nan? || x.negative?
      return -Float::INFINITY if x.zero?
      return asymptotic_y(1, x) if x > 30

      # Y1 = 2/pi (ln(x/2) + gamma) J1 - 2/(pi x)
      #      - 1/pi sum_{k>=0} (-1)^k (H_k + H_{k+1}) (x/2)^(2k+1) / (k! (k+1)!)
      half = Rational(x) / 2
      q = half * half
      term = half # (x/2)^(2k+1) / (k! (k+1)!) at k = 0
      hk = Rational(0)
      hk1 = Rational(1)
      sum = term * (hk + hk1)
      k = 0
      loop do
        k += 1
        term = term * q / (k * (k + 1))
        hk = hk1
        hk1 += Rational(1, k + 1)
        t = term * (hk + hk1)
        sum += k.even? ? t : -t
        break if k > 5 && t.abs < sum.abs * Rational(1, 10**20)
      end
      (2.0 / Math::PI * (Math.log(x / 2) + EULER) * jn(1, x)) - (2.0 / (Math::PI * x)) - (sum.to_f / Math::PI)
    end

    # Hankel asymptotic expansion for large x
    def hankel_pq(n, x)
      mu = 4.0 * n * n
      p = 1.0
      q = 0.0
      term = 1.0
      k = 1
      loop do
        term *= (mu - (((2 * k) - 1)**2)) / (k * 8.0 * x)
        break if term.abs < 1e-17 || k > 60

        if k.odd?
          q += (k % 4 == 1 ? term : -term)
        else
          p += (k % 4 == 2 ? -term : term)
        end
        k += 1
      end
      [p, q]
    end

    def asymptotic_j(n, x)
      p, q = hankel_pq(n, x)
      w = x - (((n / 2.0) + 0.25) * Math::PI)
      Math.sqrt(2.0 / (Math::PI * x)) * ((p * Math.cos(w)) - (q * Math.sin(w)))
    end

    def asymptotic_y(n, x)
      p, q = hankel_pq(n, x)
      w = x - (((n / 2.0) + 0.25) * Math::PI)
      Math.sqrt(2.0 / (Math::PI * x)) * ((p * Math.sin(w)) + (q * Math.cos(w)))
    end
  end
end
