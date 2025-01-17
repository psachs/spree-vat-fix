TaxRate.class_eval do
  def is_default?
    self.tax_category.is_default
  end
end

Calculator::Vat.class_eval do
  # list the vat rates for the default country
  def self.default_rates(user_ip = nil, country_code = nil)
    # try to determine user country by geolocation
    country = Country.find_by_iso(country_code.upcase) unless country_code.nil?
    country ||= Country.find_by_iso(GeoLocation.find(user_ip)[:country_code]) unless user_ip.nil?
    origin = country || Country.find(Spree::Config[:default_country_id])
    calcs = Calculator::Vat.find(:all, :include => {:calculable => :zone}).select {
      |vat| vat.calculable.zone.country_list.include?(origin)
    }
    calcs.collect { |calc| calc.calculable }
  end

  def self.rates_for_order(order, user_ip = nil, country_code = nil)
    return default_rates(user_ip, country_code) if order.nil? || order.ship_address.nil? || order.ship_address.country.nil?
    calcs = Calculator::Vat.find(:all, :include => {:calculable => :zone}).select {
      |vat| vat.calculable.zone.country_list.include?(order.ship_address.country)
    }
    calcs.collect { |calc| calc.calculable }
  end

  # Called by BaseHelper.order_price to determine the tax, before address is known. While off course possibly incorrct,
  # default assumtion leads to correct value in 90 ish % of cases or more.
  def self.calculate_tax(order, user_ip = nil, country_code = nil)
    rates = rates_for_order(order, user_ip, country_code)
    tax = 0
    order.line_items.each do |line_item|
      variant = line_item.variant
      tax += (calculate_tax_on(variant , rates) * line_item.quantity)
    end
    tax
  end

  # called when showing a product on the consumer side (check ProductsHelper)
  def self.calculate_tax_on(product_or_variant , vat_rates = default_rates )
    return 0 if vat_rates.nil?  # uups, configuration error
    product = product_or_variant.is_a?(Product) ? product_or_variant : product_or_variant.product
    return 0 unless product.tax_category_id?
    tax_category = product.tax_category
    # TODO finds first (or any?) rate.
    return 0 unless rate = vat_rates.find { | vat_rate | vat_rate.tax_category_id == tax_category.id }
    puts "CALCULATE TAX ON #{product_or_variant.price}  RATE#{ rate.amount}"
    BigDecimal((product_or_variant.price * rate.amount).to_s).round(2, BigDecimal::ROUND_HALF_UP)
  end

  # computes vat for line_items associated with order, and tax rate and now coupon discounts are taken into account in tax calcs
  def compute(order)
    rate = self.calculable
    tax = 0
    return 0 unless order.ship_address.nil? || order.ship_address.country.nil? || rate.zone.country_list.include?(order.ship_address.country)

    if rate.tax_category.is_default and !Spree::Config[ :show_price_inc_vat]
      order.adjustments.each do | adjust |
        next if adjust.originator_type == "TaxRate"
        add = adjust.amount * rate.amount
        puts "Applying default rate to adjustment #{adjust.label} (#{adjust.originator_type} ), sum = #{add}"
        tax += add
      end
    end
    order.line_items.each do  | line_item|
      # do not apply tax_rate if product has no tax_category
      next unless line_item.product.tax_category_id?
      next unless line_item.product.tax_category == rate.tax_category
      next unless line_item.product.tax_category.tax_rates.include? rate
      tax += BigDecimal((line_item.price * rate.amount).to_s).round(2, BigDecimal::ROUND_HALF_UP) * line_item.quantity
    end
    tax
  end

end
