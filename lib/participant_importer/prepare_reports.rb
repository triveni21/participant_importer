module ParticipantImporter
  module PrepareReports

  # This method generates new_hire, payroll records and missing participants report
  def generate_reports
    # Hack to override @date for Zuman
    if @records.size == 2 && @records[1].is_a?(Date)
      @date = @records[1]
      @records = @records[0]
    end

    # if @config.plan.sponsor_name == "NVN Management" && @config.payroll_provider.name == "s3"
    if @config.div_id.present?
      # PayrollSetup.div_id is the LT trust division ID and we should add it to the file name if it exists
      file_name_prefix = "#{@date.to_s()}-#{@config.plan.symlink}-#{@config.div_id.strip}"
    else
      file_name_prefix = "#{@date.to_s()}-#{@config.plan.symlink}"
    end
    files = []
    if @new_employees.present?
      new_hire_report = generate_new_hire_report
      files.push({
        name: "#{file_name_prefix}-new-hire-report.csv",
        description: 'New Hire Report',
        content: new_hire_report,
        content_type: 'text/csv',
      })
    end

    Rails.logger.info("#Records = #{@records.size}, #New hires = #{@new_employees.size()}")

    rk_report = generate_record_keeper_report
    files.push({
      name: "#{file_name_prefix}-payroll-report.csv",
      description: 'Payroll Report',
      content: rk_report,
      content_type: 'text/csv',
    })

    if @records_without_participant_ids.present?
      participant_mapping_missing_report = generate_participant_mapping_missing_report
      files.push({
        name: "#{file_name_prefix}-participant-mapping-missing-report.csv",
        description: 'Participant mapping missing Report',
        content: participant_mapping_missing_report,
        content_type: 'text/csv',
      })
    end
    return files
  end

  # This method needs to be synched with the same method from payroll repo
  def email_subject
    sponsor_name = @config.plan.sponsor_name
    display_date = @date.to_s()
    if @config.div_id.present?
      email_subject = "Payroll report for #{sponsor_name} for division #{@config.division_name}: #{display_date}"
    else
      email_subject = "Payroll report for #{sponsor_name}: #{display_date}"
    end
    return email_subject
  end

  # This method needs to be synched with the same method from payroll repo
  def email_body
    sponsor_name = @config.plan.sponsor_name
    message = 'Hi there!'\
      '<br />'\
      '<br />'\
      "#{sponsor_name} has run their payroll. Please download the relevant reports below."\
      '<br />'\
      '<br />'
    message
  end

  def save_files(files)
    files.each do |file_info|
      file_url = upload_file_to_s3(file_info)
      file_info[:url] = file_url
    end
  end

  def send_report(files)
    subject = email_subject()
    message = email_body()
    to_message = {to: [{email: report_subscribers}], from_email: 'payroll-integration@forusall.com', subject: subject}
    files.each do |file_info|
      file_description = file_info.fetch(:description)
      file_url = file_info.fetch(:url)

      message += "<a href = #{file_url} style='padding: 20px; background-color: #0386fc; color: #fff; display: block; width: 200px; text-align: center;'>Download #{file_description}</a>"\
        '</a>'\
        '<br /><br />'
    end
    message += 
      '--'\
      '<br />'\
      'Your friendly payroll integrator.'\
      '<br />'\
      '<br />'\
      "<div style='margin-top: 10px;'>&nbsp;</div>"
    handler = Proc.new do |exception, attempt_number|
      if exception.present?
        Rails.logger.error("Failed to send report at #{attempt_number} time. Exception #{exception.message}")
      end
    end
    
    with_retries(:max_tries => 4, :handler => handler) do |attempt|
      result=Mandrill::API.new(@mandrill_key).messages.send to_message.merge(
        html: message
      )
    end
  end

  def upload_file_to_s3(file_info)
    file_name = file_info.fetch(:name)
    file_content = file_info.fetch(:content)
    content_type = file_info.fetch(:content_type)
    credentials = Aws::Credentials.new(@aws_access_key_id, @aws_secret_access_key)
    client = Aws::S3::Client.new(region: 'us-east-1', credentials: credentials)
    resource = Aws::S3::Resource.new(client: client) 
    bucket = resource.bucket(@bucket_name)
    bucket.put_object({
      key: file_name,
      body: file_content,
      acl: 'authenticated-read',
      server_side_encryption: 'AES256',
      content_disposition: "attachment; filename=#{file_name}",
      content_type: content_type,
    })
    Rails.logger.info("Saved report to S3 (#{@bucket_name}/#{file_name})")
    return s3_url(file_name)
  end

  def s3_url(file_name)
    credentials = Aws::Credentials.new(@aws_access_key_id, @aws_secret_access_key)
    client = Aws::S3::Client.new(region: 'us-east-1', credentials: credentials)
    resource = Aws::S3::Resource.new(client: client) 
    bucket = resource.bucket(@bucket_name)
    object = bucket.object(file_name)
    object.presigned_url(:get, expires_in: 604800)
  end

  def report_subscribers
    if @report_subscriber.nil?
      raise 'Missing report subscriber. Unable to send report'
    end
    @report_subscriber
  end

    # # This method needs to be synched with the same method in report file from payroll repo
    # def generate_header(schema)
    #   header = []
    #   schema.each do |field_name, field_config|
    #     header.push(field_config.fetch(:column_title))
    #   end
    #   return header
    # end

    # # This method needs to be synched with the same method in report file from payroll repo
    # def generate_header_and_body(schema, records)
    #   return generate_header(schema), generate_body_rows(records)
    # end

    # # This method needs to be synched with the same method in report file from payroll repo
    # def generate_report(records)
    #   # Generate RK report given parsed payroll records
    #   schema = declare_schema()
    #   # each element in rows is an array, extracted from each record
    #   header, rows = generate_header_and_body(schema, records)
      
    #   create_formatted_payroll_records(records)
      
    #   csv_string = CSV.generate do |csv|
    #     csv << header
    #     rows.each do |cells|
    #       csv << cells
    #     end
    #   end

    #   return csv_string
    # end

    def generate_record_keeper_report
      config = @config.plan.record_keeper#fetch('record_keeper')
      report = FormatReport.new
      report.pay_date @date

      report.config = @config
      return report.generate_report(@records)
    end

    # This method needs to be synched with the same method from payroll repo
    def generate_new_hire_report
      lines = []

      column_titles = [
        'Social Security Number',
        'Name - Last',
        'Name - First',
        'Gender',
        'Date of Birth',
        'Date of Hire - Original',
        'Date of Rehire',
        'Termination Date',
        'Address - Street 1',
        'Address - Street 2',
        'Address - City',
        'Address - State',
        'Address - Postal Code',
        'Division ID',
        'Pre-tax Deferral',
        'Roth Amount',
        'Matching Amount',
        'Matching Safe Harbor',
        'Profit Sharing',
        'Non Elective Safe Harbor',
        'Plan Compensation',
        'Current Hours',
        'Marital Status',
        'Loan Payments',
        'Internet Address - Other',
        'PARTICIPANTID'
      ]
      lines.push(column_titles.join(','))

      plan_symlink = @config.plan.symlink
      plan = Plan.where('symlink = ?', plan_symlink).first
      @new_employees.each do |employee|
        date_of_birth = employee[RecordField::DATE_BIRTH]
        if date_of_birth.present? && date_of_birth.is_a?(Date)
          date_of_birth = DateUtils.to_string(date_of_birth)
        else
          date_of_birth = ''.to_date
        end
        participant = participant_mapping(plan.id, employee, date_of_birth)
        next if participant.nil?

        calculate_assumed_hour = Plan.calculate_assumed_hour(employee, plan.id)
        hours = plan.assumed_hours_setting ?  calculate_assumed_hour : employee[RecordField::HOURS_REGULAR]
        cells = [
          (employee[RecordField::SSN] || '').gsub(/[^\d]/, ''),
          employee[RecordField::NAME_LAST],
          employee[RecordField::NAME_FIRST],
          employee[RecordField::GENDER] || '',
          employee[RecordField::DATE_BIRTH] || ' ',
          employee[RecordField::DATE_HIRE] || ' ',
          employee[RecordField::DATE_REHIRE] || ' ',
          employee[RecordField::DATE_TERMINATION] || ' ',
          employee[RecordField::ADDRESS_STREET_1],
          employee[RecordField::ADDRESS_STREET_2],
          employee[RecordField::ADDRESS_CITY],
          employee[RecordField::ADDRESS_STATE],
          employee[RecordField::ADDRESS_POSTAL_CODE],
          employee[RecordField::DIVISION_ID],
          employee[RecordField::AMOUNT_CONTRIBUTION_TRADITIONAL],
          employee[RecordField::AMOUNT_CONTRIBUTION_ROTH],
          employee[RecordField::AMOUNT_MATCH],
          employee[RecordField::AMOUNT_MATCH_SAFE_HARBOR],
          employee[RecordField::AMOUNT_PROFIT_SHARING],
          employee[RecordField::AMOUNT_NON_ELECTIVE_SAFE_HARBOR],
          employee[RecordField::AMOUNT_PAY_GROSS],
          hours,
          employee[RecordField::MARITAL_STATUS],
          employee[RecordField::AMOUNT_LOAN_PAYMENTS],
          employee[RecordField::EMAIL] || ' ',
          participant.try(:id)
        ]
        lines.push(cells.join(','))
      end

      return lines.join("\n")
    end

    # This method needs to be synched with the same method from payroll repo
    def generate_participant_mapping_missing_report
      lines = []

      column_titles = [
        'PLANID',
        'SSNUM',
        'FIRSTNAM',
        'LASTNAM',
        'BIRTHDATE',
        'HIREDATE',
        'DEFERPCT',
        'EMAIL',
        'PHONEADDR',
        'SALARY',
      ]
      lines.push(column_titles.join(','))

      plan_symlink = @config.plan.symlink
      @records_without_participant_ids.each do |record|
        date_of_birth = record[:record][RecordField::DATE_BIRTH]
        date_of_birth = DateUtils.to_string(date_of_birth) if date_of_birth.present?
        cells = [
          plan_symlink,
          record[:record][RecordField::SSN],
          record[:record][RecordField::NAME_FIRST],
          record[:record][RecordField::NAME_LAST],
          date_of_birth,
          record[:record][RecordField::DATE_HIRE],
          ' ',
          record[:record][RecordField::EMAIL],
          '',
          ''
        ]
        lines.push(cells.join(','))
      end

      return lines.join("\n")
    end
  end
end