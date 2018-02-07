module ParticipantImporter
	module LoadData
		# This method creates Payroll records
	  def create_payroll_records
	    plan_id = @config.plan_id
	    pay_date = DateUtils.to_string(@date, "%Y-%m-%d")
	    download_date = Date.today
	    # records_validations = {}
	    # This doesn't look right. What if we run payroll for a second time and there are more records?
	    existing_record = PayrollRecord.find_by({
	      plan_id: plan_id,
	      date_pay: pay_date,
	    })

	    if !existing_record.nil?
	      Rails.logger.info("Records already saved in DB. Not saving new records.")
	      return @records_without_participant_ids #, records_validations
	    end

	    PayrollRecord.transaction do
	      @records.each do |record|
	        # TODO: DB should allow this to be nil
	        date_of_birth = record[RecordField::DATE_BIRTH]
	        if date_of_birth.present? && date_of_birth.is_a?(Date)
	          date_of_birth = DateUtils.to_string(date_of_birth)
	        else
	          date_of_birth = ''.to_date
	        end
	        participant = participant_mapping(plan_id, record, date_of_birth)

	        # if participant
	        #   records_validations = LtTrustValidator.validate(record, participant, records_validations)
	        # end
	        ssn = (record[RecordField::SSN] || '').gsub(/[^\d]/, '')
	        PayrollRecord.create({
	          plan_id: plan_id,
	          date_pay: pay_date,
	          participant_id: participant.try(:id),
	          date_of_birth: date_of_birth || '',
	          record: Oj.dump(record),
	          ssn: ssn,
	          record: Oj.dump(record),
	          date_download: download_date,
	          name_last: record[RecordField::NAME_LAST],
	          name_first: record[RecordField::NAME_FIRST],
	          date_birth: date_of_birth || '',
	          date_hire: record[RecordField::DATE_HIRE],
	          date_rehire: record[RecordField::DATE_REHIRE],
	          date_termination: record[RecordField::DATE_TERMINATION],
	          city: record[RecordField::ADDRESS_CITY],
	          state: record[RecordField::ADDRESS_STATE],
	          postal_code: record[RecordField::ADDRESS_POSTAL_CODE],
	          division_id: record[RecordField::DIVISION_ID],
	          amount_contribution_traditional: record[RecordField::AMOUNT_CONTRIBUTION_TRADITIONAL],
	          amount_contribution_roth: record[RecordField::AMOUNT_CONTRIBUTION_ROTH],
	          benefit_name_traditional: @config.benefit_name_traditional,
	          benefit_name_roth: @config.benefit_name_roth,
	          amount_match: record[RecordField::AMOUNT_MATCH],
	          amount_match_safe_harbor: record[RecordField::AMOUNT_MATCH_SAFE_HARBOR],
	          amount_profit_sharing: record[RecordField::AMOUNT_PROFIT_SHARING],
	          amount_non_elective_safe_harbor: record[RecordField::AMOUNT_NON_ELECTIVE_SAFE_HARBOR],
	          amount_pay_gross: record[RecordField::AMOUNT_PAY_GROSS],
	          hours: record[RecordField::HOURS_REGULAR],
	          amount_loan_payments: record[RecordField::AMOUNT_LOAN_PAYMENTS],
	          amount_loan_payments_hash: record[RecordField::AMOUNT_LOAN_PAYMENTS_HASH] || {},
	          email: record[RecordField::EMAIL]
	        })
	      end
	    end
	  end

	  # This method needs to be synched with the same method from payroll repo
	  def process_participants
	    plan_id = @config.plan_id
	    @records.each do |record|

	      date_of_birth = record[RecordField::DATE_BIRTH]
	      if date_of_birth.present? && date_of_birth.is_a?(Date)
	        date_of_birth = DateUtils.to_string(date_of_birth)
	      else
	        date_of_birth = ''.to_date
	      end

	      date_of_hire = record[RecordField::DATE_HIRE]

	      if date_of_hire.present? && date_of_hire.is_a?(Date)
	        date_of_hire = DateUtils.to_string(date_of_hire)
	      else
	        date_of_hire = ''.to_date
	      end

	      ssn = (record[RecordField::SSN] || '').gsub(/[^\d]/, '')

	      if ssn.present?
	        participant = Participant.find_by_plan_id_and_full_ssn(plan_id, ssn)
	      else
	        participant = Participant.where('plan_id = ? and first_name = ? and last_name = ? and birth_date = ?',
	        plan_id, record[RecordField::NAME_FIRST], record[RecordField::NAME_LAST], date_of_birth)
	        if participant.length > 1
	          participant = Participant.where('plan_id = ? and first_name = ? and last_name = ? and birth_date = ? and hire_date = ?',
	          plan_id, record[RecordField::NAME_FIRST], record[RecordField::NAME_LAST], date_of_birth, date_of_hire)
	        end
	        participant = participant.first
	      end

	      if participant.blank?
	        @new_employees << record
	      else
	        create_participant_hours(record, participant, plan_id)
	        participant.update_participant_record(record, @config.id, @config.payroll_provider.short_name)
	        if participant.participant_contact_information
	          participant.update_participant_contact_information(record)
	        else
	          create_participant_contact_information(record, participant)
	        end
	        record[RecordField::SSN] = participant.full_ssn if record[RecordField::SSN].blank?
	      end

	      employee = Employee.maybe_find_record(plan_id, record)

	      if employee.nil?
	        employee = Employee.create_from_record(plan_id, record)
	        next
	      end

	      employee.update_from_record(record)
	    end
	    create_new_hire_participants(@new_employees)
	  end

	  def participant_mapping(plan_id, record, birth_date)
	    ssn = (record[RecordField::SSN] || '').gsub(/[^\d]/, '')
	    #if @new_employees.include?(Employee.maybe_find_record(plan_id, record)) # No participant mapping if new employee
	     # participant = nil
	    if ssn.present?
	      participant = Participant.find_by_plan_id_and_active_and_full_ssn(plan_id, true, ssn)
	      @records_without_participant_ids << {record: record, reason: 'Missing participant with given ssn'} if participant.blank? # No participant mapping if no participant with ssn
	    else
	      participant = Participant.where('plan_id = ? and first_name = ? and last_name = ?
	        and active is true',
	        plan_id, record[RecordField::NAME_FIRST], record[RecordField::NAME_LAST])

	      if participant.length == 1
	        return participant.first
	      end

	      participant = Participant.where('plan_id = ? and first_name = ? and last_name = ?
	        and birth_date = ? and active is true',
	        plan_id, record[RecordField::NAME_FIRST], record[RecordField::NAME_LAST], birth_date)

	      if participant.length > 1
	        @records_without_participant_ids << {record: record, reason: 'Multiple participants found with given name'}
	        participant = nil
	        return participant
	      end

	      if participant.blank?
	        @records_without_participant_ids << {record: record, reason: 'Missing participant with given name'}
	        participant = nil
	        return participant
	      end

	      if participant.length == 1
	        return participant.first
	      end
	    end

	    return participant
	  end

	  def create_new_hire_participants(records)
	  	plan_symlink = @config.plan.symlink
      plan = Plan.where('symlink = ?', plan_symlink).first
      records.each do |employee|
        participant = create_new_hire_participant(employee, plan)
        create_participant_hours(employee, participant, plan.id)
        # calculate_assumed_hour = Plan.calculate_assumed_hour(employee, plan.id)
        # hours = plan.assumed_hours_setting ?  calculate_assumed_hour : employee[RecordField::HOURS_REGULAR]
      end
	  end

	  def create_new_hire_participant(record, plan)
	    employee = record.dup
	    total_records = 0
	    records_processed = 0
	    records_not_processed = 0
	    no_error_while_loading = true
	    total_records += 1
	    no_error_while_loading = true
	    selected_values = []
	    current_date = Date.today
	    if employee[RecordField::SSN].blank?
	      return false
	    end

	    ssn = employee[RecordField::SSN].to_i if employee[RecordField::SSN].is_a?(Float)
	    ssn = employee[RecordField::SSN].to_s if employee[RecordField::SSN].is_a?(Fixnum)
	    ssn = employee[RecordField::SSN].scan(/\d/).join('')
	    if ssn.length != 9 || (ssn =~ /^\d+$/).blank?
	      return false
	    end
	    employee[RecordField::SSN] = ssn
	    employee[RecordField::NAME_FIRST] = employee[RecordField::NAME_FIRST].gsub(/[“”]/, '') if !employee[RecordField::NAME_FIRST].nil?
	    employee[RecordField::NAME_FIRST] = employee[RecordField::NAME_FIRST].try(:strip)
	    employee[RecordField::NAME_LAST] = employee[RecordField::NAME_LAST].gsub(/[“”]/, '') if !employee[RecordField::NAME_LAST].nil?
	    employee[RecordField::NAME_LAST] = employee[RecordField::NAME_LAST].try(:strip)

	    if employee[RecordField::EMAIL].present?
	      employee[RecordField::EMAIL] = employee[RecordField::EMAIL].strip
	    end

	    if employee[RecordField::DATE_BIRTH].blank?
	      return false
	    end

	    begin
	      employee[RecordField::DATE_BIRTH] = Date.parse(employee[RecordField::DATE_BIRTH].to_s).to_date.strftime('%Y-%m-%d')
	    rescue => ex
	      raise "Date format error occured for the birth date for employee #{employee[RecordField::SSN]}: #{ex.try(:message)}"
	      return false
	    end

	    if employee[RecordField::DATE_HIRE].blank?
	      return false
	    end

	    begin
	      employee[RecordField::DATE_HIRE] = Date.parse(employee[RecordField::DATE_HIRE].to_s).to_date.strftime('%Y-%m-%d') if employee[RecordField::DATE_HIRE].present?
	    rescue => ex
	      raise "Date format error occured for the hire date for employee #{employee[RecordField::SSN]}: #{ex.try(:message)}"
	      return false
	    end

	    if !Participant.find_by_full_ssn_and_plan_id(employee[RecordField::SSN], plan.id).nil?
	      return false
	    end

	    begin
	      participant = Participant.new#Participant.find_by_full_ssn_and_plan_id(employee.ssn, employee.plan_id) || Participant.new
	      participant.full_ssn = employee[RecordField::SSN]
	      participant.partial_ssn = employee[RecordField::SSN].split(//).last(4).join()
	      participant.first_name = employee[RecordField::NAME_FIRST]
	      participant.last_name = employee[RecordField::NAME_LAST]
	      participant.email = employee[RecordField::EMAIL]
	      participant.payroll_email = employee[RecordField::EMAIL]
	      participant.plan_id = plan.id
	      participant.realm = 'prod'
	      participant.birth_date = employee[RecordField::DATE_BIRTH]
	      participant.hire_date = employee[RecordField::DATE_HIRE]
	      participant.termination_date = employee[RecordField::DATE_TERMINATION]
	      participant.rehire_date = employee[RecordField::DATE_REHIRE]
	      participant.updated_by = 'participant_importer'
	      participant.updated_by_id = nil
	      participant.projected_plan_entry_date = EligibilityRule.projected_plan_entry_date(plan, participant)

	      participant.eligibility_status = participant.calculate_participant_eligibility_status
	      # participant.ssn_validated_by = 'payroll-import'
	      # participant.ssn_validated = true
	      if employee[RecordField::PHONE_NUMBER].is_a?(Float)
	        employee[RecordField::PHONE_NUMBER] = employee[RecordField::PHONE_NUMBER].to_i
	      end
	      participant.phone = employee[RecordField::PHONE_NUMBER].to_s.scan(/\d/).last(10).join('') if employee[RecordField::PHONE_NUMBER].present?
	      participant.payroll_setup_id = @config.id
	      if participant.save
	        create_default_plan_settings(participant, plan.id, nil)
	        create_participant_contact_information(employee, participant)
	      else
	        return false
	      end
	    rescue
	      participant = nil
	    end
	    return participant
		end

		def create_default_plan_settings record, plan_id
	  	participant_current_plan_setting = record.participant_current_plan_setting
	    if participant_current_plan_setting.nil?
	      plan = Plan.where("id = ?", plan_id.to_i).first
	      if plan
	        participant_current_plan_setting = ParticipantCurrentPlanSetting.new
	        plan_info = nil
	        plan_context = Oj.load(plan.plan)
	        plan_info = !plan.blank? && plan_context.key?("benefits") ? plan_context["benefits"].select { |x| x["code"] == "401k" }.first.symbolize_keys : nil
	        if plan_info
	          dob = record.birth_date
	          investor_type, _, default_election = record.default_investment
	          default_investment = dob ? investor_type : plan_info[:default_personalize_investments]  # kinda weird, but keeps prior behavior
	          if ["opt_out_for_all", "opt_out_new_hires_only"].include?(plan.enrollment_type)
	            savings_rate = plan_info[:default_savings_rate].to_i
	            participant_current_plan_setting.enrolled = 1
	            participant_current_plan_setting.enrollment_type = 'auto'
	            participant_current_plan_setting.autopilot = plan_info[:default_autoescalate_rate]
	          elsif plan.enrollment_type == "opt_in_for_all"
	            savings_rate = 0
	            participant_current_plan_setting.enrolled = 0
	            participant_current_plan_setting.enrollment_type = 'opt-out'
	            participant_current_plan_setting.autopilot = false
	          else
	            raise "Failed to create participant_current_plan_setting for ppt (id: #{record.id}) due to plan(id: #{plan.id}) enrollment_type #{plan.enrollment_type} isn't supported."
	          end
	          savings_type = plan_info[:default_401k_type]
	          traditional_rate, roth_rate = ParticipantCurrentPlanSetting.traditional_roth_rates(savings_type, savings_rate)
	          participant_current_plan_setting.traditional_rate = traditional_rate
	          participant_current_plan_setting.roth_rate = roth_rate
	          participant_current_plan_setting.investor_type = default_investment
	          participant_current_plan_setting.investment_elections = default_election
	          participant_current_plan_setting.participant_id = record.id
	          participant_current_plan_setting.updated_by = 'participant_importer'
	          participant_current_plan_setting.updated_by_id = nil
	          participant_current_plan_setting.save
	        else
	          raise 'No default settings found for the given plan'
	        end
	      else
	        raise 'No plan found for the given plan_id'
	      end
	    end
		end

	  # This method needs to be synched with the same method from payroll repo
	  def create_participant_hours(employee, participant, plan_id)
	    if participant.present?
	      plan = Plan.find(plan_id)
	      assumed_hours = PlanAssumedHour.find_by_plan_id(plan).assumed_hours
	      calculate_assumed_hour = Plan.calculate_assumed_hour(employee, plan_id)
	      hours = plan.assumed_hours_setting ?  calculate_assumed_hour : employee[RecordField::HOURS_REGULAR]
	      total_hours = hours.to_f + assumed_hours.to_f

	      # The below code will check whether record is present for pay and update record if present
	      pay_date = DateUtils.to_string(@date, "%Y-%m-%d")
	      existing_payroll_record = PayrollRecord.where(participant_id: participant.id, date_pay: pay_date
	        ).first
	      end_date = existing_payroll_record ? existing_payroll_record.date_pay - 1 : nil
	      existing_participant_hour_record = ParticipantHour.where(participant_id: participant.id,
	        ending_date: end_date).order('created_at desc').first
	      beginning_date = existing_participant_hour_record ? existing_participant_hour_record.beginning_date : nil
	      ending_date = existing_participant_hour_record ? existing_participant_hour_record.ending_date : nil
	      participant_hour_record = ParticipantHour.where("participant_id = ? AND beginning_date = ? AND ending_date = ?",
	          participant.id, beginning_date, ending_date).first

	      if participant_hour_record.present?
	        beginning_date = beginning_date
	        ending_date = ending_date
	        Rails.logger.info("Records already saved in DB for #{beginning_date} and #{ending_date} for Id #{participant.id}.So updating existing_record")
	      else
	        payroll_records = PayrollRecord.where("participant_id = ? AND date_pay < ?",
	          participant.id, @date).order('date_pay desc').first
	        beginning_date = payroll_records ? (payroll_records.date_pay) : participant.hire_date
	        ending_date = @date - 1.day
	      end

	      begin
	        participant_hour = participant_hour_record || ParticipantHour.new
	        participant_hour.participant_id = participant.id
	        participant_hour.beginning_date = beginning_date
	        participant_hour.ending_date = ending_date
	        participant_hour.paycheck_date = @date
	        participant_hour.hours = hours
	        participant_hour.assumed_hours = assumed_hours
	        participant_hour.total_hours = total_hours
	        participant_hour.notes = 'participant_importer'
	        participant_hour.updated_by = 'participant_importer'
	        if participant_hour.save
	          all_participant_hour_attributes = participant_hour.attributes.dup
	          all_participant_hour_attributes.merge!({ participant_id: participant.id })
	          ["id", "updated_at", "created_at"].each{ |k| all_participant_hour_attributes.delete(k) }
	          AllParticipantHour.create!(all_participant_hour_attributes)
	        else
	          false
	        end
	      rescue
	        participant_hour = nil
	      end
	      return participant_hour
	    else
	      Rails.logger.info('No participant found for the given plan')
	    end
		end

		# This method needs to be synched with the same method from payroll repo
	  def create_participant_contact_information(employee, participant)
	    if employee
	      ParticipantContactInformation.create({
	        participant_id: participant.id,
	        address_1: employee[RecordField::ADDRESS_STREET_1],
	        address_2: employee[RecordField::ADDRESS_STREET_2],
	        city: employee[RecordField::ADDRESS_CITY],
	        state: employee[RecordField::ADDRESS_STATE],
	        zipcode: employee[RecordField::ADDRESS_POSTAL_CODE],
	        address_1_payroll: employee[RecordField::ADDRESS_STREET_1],
	        address_2_payroll: employee[RecordField::ADDRESS_STREET_2],
	        city_payroll: employee[RecordField::ADDRESS_CITY],
	        state_payroll: employee[RecordField::ADDRESS_STATE],
	        zipcode_payroll: employee[RecordField::ADDRESS_POSTAL_CODE]
	        #first_name_payroll: employee[RecordField::NAME_FIRST]
	        })
	    else
	      Rails.logger.info('No participant found for the given plan')
	    end
	  end

	  # This method needs to be synched with the same method in report file from payroll repo
	  def create_formatted_payroll_records
	    pay_date =  self.try(:get_pay_date) #DateUtils.to_string(@date, "%Y-%m-%d")
	    download_date = Date.today #DateUtils.to_string(Date.today, "%Y-%m-%d")
	    plan_id = @config.plan_id
	    payroll_provider_id = @config.payroll_provider_id
	    existing_record = PayrollFormattedRecord.find_by({
	      plan_id: plan_id,
	      date_pay: pay_date,
	    })
	    if !existing_record.nil?
	      Rails.logger.info("Records already saved in DB. Not saving new records.")
	      return
	    end

	    # Should we remove this model? It is just a duplicate of payroll_records
	    PayrollFormattedRecord.transaction do
	      records.each do |record|
	        ssn = (record[RecordField::SSN] || '').gsub(/[^\d]/, '')
	        if record[RecordField::SSN].present?
	          payroll_record = PayrollRecord.find_by_plan_id_and_date_pay_and_ssn(
	            plan_id, pay_date, ssn
	          )
	        else
	          birth_date = record[RecordField::DATE_BIRTH].blank? ? ''.to_date : record[RecordField::DATE_BIRTH]
	          payroll_record = PayrollRecord.find_by_plan_id_and_date_pay_and_name_first_and_name_last_and_date_birth(
	            plan_id, pay_date, record[RecordField::NAME_FIRST], record[RecordField::NAME_LAST], birth_date
	          )
	        end

	        if payroll_record
	          PayrollFormattedRecord.create({
	            payroll_record_id: payroll_record.id,
	            plan_id: plan_id,
	            date_pay: pay_date,
	            participant_id: payroll_record.participant_id,
	            ssn: record[RecordField::SSN],
	            record: Oj.dump(record),
	            date_download: download_date,
	            name_last: record[RecordField::NAME_LAST],
	            name_first: record[RecordField::NAME_FIRST],
	            date_birth: birth_date,
	            date_hire: record[RecordField::DATE_HIRE],
	            date_rehire: record[RecordField::DATE_REHIRE],
	            date_termination: record[RecordField::DATE_TERMINATION],
	            city: record[RecordField::ADDRESS_CITY],
	            state: record[RecordField::ADDRESS_STATE],
	            postal_code: record[RecordField::ADDRESS_POSTAL_CODE],
	            division_id: record[RecordField::DIVISION_ID],
	            amount_contribution_traditional: record[RecordField::AMOUNT_CONTRIBUTION_TRADITIONAL],
	            amount_contribution_roth: record[RecordField::AMOUNT_CONTRIBUTION_ROTH],
	            benefit_name_traditional: @config.benefit_name_traditional,
	            benefit_name_roth: @config.benefit_name_roth,
	            amount_match: record[RecordField::AMOUNT_MATCH],
	            amount_match_safe_harbor: record[RecordField::AMOUNT_MATCH_SAFE_HARBOR],
	            amount_profit_sharing: record[RecordField::AMOUNT_PROFIT_SHARING],
	            amount_non_elective_safe_harbor: record[RecordField::AMOUNT_NON_ELECTIVE_SAFE_HARBOR],
	            amount_pay_gross: record[RecordField::AMOUNT_PAY_GROSS],
	            hours: record[RecordField::HOURS_REGULAR],
	            amount_loan_payments: record[RecordField::AMOUNT_LOAN_PAYMENTS],
	            email: record[RecordField::EMAIL]
	          })
	        end
	      end
	    end
	  end
	end
end