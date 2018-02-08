require 'participant_importer/version'
require 'participant_importer/record_field'
require 'participant_importer/load_data'
require 'participant_importer/prepare_reports'
require 'participant_importer/format_report'

module ParticipantImporter
  class << self
  	include LoadData
  	include PrepareReports

    attr_accessor :records, :date, :config

    def initialize(options={})
      @records = options[:records]
      @date = options[:date].is_a?(String) ? options[:date].to_date : options[:date]
      @config = options[:config]
      @report_subscriber = options[:report_subscriber]
      @new_employees = []
      @records_without_participant_ids = []
      @generate_report = options[:generate_report] || false
      @mandrill_key = options[:mandrill_key]
      @aws_access_key_id = options[:aws_credentials][:aws_access_key_id]
      @aws_secret_access_key = options[:aws_credentials][:aws_secret_access_key]
      @bucket_name = options[:bucket_name]
    end

    def execute
      files = nil
    	process_participants
      create_payroll_records
    	create_formatted_payroll_records
    	if @generate_report
    		files = generate_reports
    		save_files(files)
    		send_report(files)
    	end

      files
    end

  end
end
