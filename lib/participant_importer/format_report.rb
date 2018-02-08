class FormatReport

  attr_accessor :date, :config

  def declare_schema
    return {
      RecordField::SSN => {
        column_title: 'Social Security Number',
        optional: true, # Will have a warning in payroll validation
        # Generate the internal format report is done at the last step of the download job
        # So we do not need to worry about breaking the previous logic when we relax the restriction for SSN here
      },
      RecordField::NAME_LAST => {
        column_title: 'Name - Last',
      },
      RecordField::NAME_FIRST => {
        column_title: 'Name - First',
      },
      RecordField::GENDER => {
        column_title: 'Gender',
        optional: true,
      },
      RecordField::DATE_BIRTH => {
        column_title: 'Date of Birth',
        optional: true,
      },
      RecordField::DATE_HIRE => {
        column_title: 'Date of Hire - Original',
        optional: true,
      },
      RecordField::DATE_REHIRE => {
        column_title: 'Date of Rehire',
        optional: true,
      },
      RecordField::DATE_TERMINATION => {
        column_title: 'Termination Date',
        optional: true,
      },
      RecordField::ADDRESS_STREET_1 => {
        column_title: 'Address - Street 1',
        optional: true,
      },
      RecordField::ADDRESS_STREET_2 => {
        column_title: 'Address - Street 2',
        optional: true,
      },
      RecordField::ADDRESS_CITY => {
        column_title: 'Address - City',
        optional: true,
      },
      RecordField::ADDRESS_STATE => {
        column_title: 'Address - State',
        optional: true,
      },
      RecordField::ADDRESS_POSTAL_CODE => {
        column_title: 'Address - Postal Code',
        optional: true,
      },
      RecordField::DIVISION_ID => {
        column_title: 'Division ID',
        optional: true,
      },
      RecordField::AMOUNT_CONTRIBUTION_TRADITIONAL => {
        column_title: 'Pre-tax Deferral',
      },
      RecordField::AMOUNT_CONTRIBUTION_ROTH => {
        column_title: 'Roth Amount',
      },
      RecordField::AMOUNT_MATCH => {
        column_title: 'Matching Amount',
        optional: true,
      },
      RecordField::AMOUNT_MATCH_SAFE_HARBOR => {
        column_title: 'Matching Safe Harbor',
        optional: true,
      },
      RecordField::AMOUNT_PROFIT_SHARING => {
        column_title: 'Profit Sharing',
        optional: true,
      },
      RecordField::AMOUNT_NON_ELECTIVE_SAFE_HARBOR => {
        column_title: 'Non Elective Safe Harbor',
        optional: true,
      },
      RecordField::AMOUNT_PAY_GROSS => {
        column_title: 'Plan Compensation',
      },
      RecordField::HOURS_REGULAR => {
        column_title: 'Current Hours',
        optional: true,
      },
      RecordField::MARITAL_STATUS => {
        column_title: 'Marital Status',
        optional: true,
      },
      RecordField::EMAIL => {
        column_title: 'Internet Address - Other',
        optional: true,
      },
      RecordField::AMOUNT_LOAN_PAYMENTS_HASH => {
        column_title: 'Loan Payments',
        optional: true,
      },
    }
  end

  def declare_date_format
    # return "%Y-%m-%d"
    return "%m/%d/%Y"
  end

  def declare_file_type
    return FileType::EXCELX
  end

  def pay_date date
    @date = date
  end

  def get_pay_date
    @date
  end

  def parse_field(field_name, value)
    if field_name == RecordField::GENDER
      map = {
        'M' => :male,
        'F' => :female,
      }
      return map.fetch(value)
    end

    if field_name == RecordField::MARITAL_STATUS
      map = {
        'M' => :married,
        'S' => :single,
        'H' => :head_of_household,
      }
      return map.fetch(value)
    end

    super
  end

  def generate_header(schema)
    header = []
    schema.each do |field_name, field_config|
      if field_name == RecordField::AMOUNT_LOAN_PAYMENTS_HASH
        next
      end
      header.push(field_config.fetch(:column_title))
    end
    return header
  end

  def generate_header_for_loan_payments_hash(records)
    header = Set.new
    records.each do |record|
      loan_payment_hash = record[RecordField::AMOUNT_LOAN_PAYMENTS_HASH]
      if loan_payment_hash.nil?
        next
      end
      header += loan_payment_hash.keys
    end
    return header.to_a
  end

  def generate_header_and_body(schema, records)
    header = generate_header(schema)
    loan_payments_header = generate_header_for_loan_payments_hash(records)
    rows = generate_body_rows(records, loan_payments_header)
    loan_payments_header.each do |key|
      header.push("Loan (#{key})")
    end
    return header, rows
  end

  def generate_body_rows(records, loan_payments_header)
    schema = declare_schema()
    rows = []
    records.each do |record|
      row = []
      values = []
      schema.each do |field_name, field_config|
        if field_name == RecordField::AMOUNT_LOAN_PAYMENTS_HASH
          loan_payment_hash = record[RecordField::AMOUNT_LOAN_PAYMENTS_HASH]
          values = parse_amount_loan_payment_hash(loan_payment_hash, loan_payments_header)
        else
          value = prepare_value_for_field(field_name, field_config[:optional], record)
          row.push(value)
        end
      end
      # append amount loan payments values at the end
      row += values
      rows.push(row)
    end
    return rows
  end

  def parse_amount_loan_payment_hash(loan_payment_hash, loan_payments_header)
    values = Array.new(loan_payments_header.size, '')
    loan_payments_header.each_with_index do |key, idx|
      val = loan_payment_hash[key]
      if val.present?
        val = export_field(RecordField::AMOUNT_LOAN_PAYMENTS, val)
        values[idx] = val
      end
    end
    return values
  end

  def export_field(field_name, value)
    if field_name == RecordField::GENDER
      map = {
        :male => 'M',
        :female => 'F',
      }
      return map.fetch(value)
    end

    if field_name == RecordField::MARITAL_STATUS
      map = {
        :married => 'M',
        :single => 'S',
        :head_of_household => 'H',
      }
      return map.fetch(value)
    end

    if field_name ==  RecordField::SSN && value.present?
      return value.gsub(/(\d{3})(\d{2})(\d{4})/, '\1-\2-\3') unless value.include?('-')
    end

    field_type = RecordField.type_for_field(field_name)
    case field_type
    when DataType::FLOAT
      return sprintf("%.2f", value)
    when DataType::DATE
      if value.year.try(:to_s).try(:length) == '2'
        return value.strftime("%m/%d/%y")
      else
        return value.strftime("%m/%d/%Y")
      end  
    end

    super
  end

  def generate_report(records)
    # Generate RK report given parsed payroll records
    schema = declare_schema()
    # each element in rows is an array, extracted from each record
    header, rows = generate_header_and_body(schema, records)

    csv_string = CSV.generate do |csv|
      csv << header
      rows.each do |cells|
        csv << cells
      end
    end

    return csv_string
  end
end
