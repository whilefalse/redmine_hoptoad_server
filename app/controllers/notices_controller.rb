class NoticesController < ApplicationController

  before_filter :check_if_login_required, :except => 'index'
  before_filter :find_or_create_custom_fields

  unloadable  

  TRACE_FILTERS = [
    /^On\sline\s#\d+\sof/,
    /^\d+:/
  ]

  def index
    notice = YAML.load(request.raw_post)['notice']    
    redmine_params = {}
    notice['api_key'].map {|k,v| redmine_params[k.to_sym] = v}

    if authorized = Setting.mail_handler_api_key == redmine_params[:api_key]
      # redmine objects
      project = Project.find_by_identifier(redmine_params[:project])
      tracker = project.trackers.find_by_name(redmine_params[:tracker])
      author = User.anonymous

      # error class and message
      error_class = notice['error_class']
      error_message = notice['error_message']

      # build filtered backtrace
      backtrace = notice['back'].blank? ? notice['backtrace'] : notice['back']
      project_trace_filters = (project.custom_value_for(@trace_filter_field).value rescue '').split(/[,\s\n\r]+/)
      filtered_backtrace = backtrace.reject{|line| (TRACE_FILTERS+project_trace_filters).map{|filter| line.scan(filter)}.flatten.compact.uniq.any?}
      
      # build subject by removing method name and '[RAILS_ROOT]', make sure it fits in a varchar
      if !filtered_backtrace.empty?
        subject = "#{error_class} in #{filtered_backtrace.first.split(':in').first.gsub('[RAILS_ROOT]','')}"[0,255]
      else
        subject = error_class
      end

      
      # build description including a link to source repository
      repo_root = project.custom_value_for(@repository_root_field).value.gsub(/\/$/,'') rescue nil
      repo_file, repo_line = filtered_backtrace.first.split(':in').first.gsub('[RAILS_ROOT]','').gsub(/^\//,'').split(':') rescue nil
      description = "Automated Redmine error notification"

      issue = Issue.find_or_initialize_by_subject_and_project_id_and_tracker_id_and_author_id(
        subject,
        project.id,
        tracker.id,
        author.id
      )
                                                                                                              
      if issue.new_record?
        # set standard redmine issue fields
        issue.category = IssueCategory.find_by_name(redmine_params[:category]) unless redmine_params[:category].blank?
        issue.assigned_to = User.find_by_login(redmine_params[:assigned_to]) unless redmine_params[:assigned_to].blank?
        issue.priority_id = redmine_params[:priority] unless redmine_params[:priority].blank?
        issue.description = description

        # make sure that custom fields are associated to this project and tracker
        project.issue_custom_fields << @error_class_field unless project.issue_custom_fields.include?(@error_class_field)
        tracker.custom_fields << @error_class_field unless tracker.custom_fields.include?(@error_class_field)
        project.issue_custom_fields << @occurences_field unless project.issue_custom_fields.include?(@occurences_field)
        tracker.custom_fields << @occurences_field unless tracker.custom_fields.include?(@occurences_field)
        
        # set custom field error class
        issue.custom_values.build(:custom_field => @error_class_field, :value => error_class)
      end

      issue.save!

      # increment occurences custom field
      value = issue.custom_value_for(@occurences_field) || issue.custom_values.build(:custom_field => @occurences_field, :value => 0)
      value.value = (value.value.to_i + 1).to_s
      logger.error value.value
      value.save!


      # update journal
      journal = issue.init_journal(
        author,
        "#{error_message}"
      )

      # reopen issue
      if issue.status.blank? or issue.status.is_closed?                                                                                                        
        issue.status = IssueStatus.find(:first, :conditions => {:is_default => true}, :order => 'position ASC')
      end

      issue.save!

      if issue.new_record?
        Mailer.deliver_issue_add(issue) if Setting.notified_events.include?('issue_added')
      else
        Mailer.deliver_issue_edit(journal) if Setting.notified_events.include?('issue_updated')
      end
      
      render :status => 200, :text => "Received bug report. Created/updated issue #{issue.id}."
    else
      logger.info 'Unauthorized Hoptoad API request.'
      render :status => 403, :text => 'You provided a wrong or no Redmine API key.'
    end
  end
  
  protected
  
  def find_or_create_custom_fields
    @error_class_field = IssueCustomField.find_or_initialize_by_name('Error class')
    if @error_class_field.new_record?
      @error_class_field.attributes = {:field_format => 'string', :searchable => true, :is_filter => true}
      @error_class_field.save(false)
    end

    @occurences_field = IssueCustomField.find_or_initialize_by_name('# Occurences')
    if @occurences_field.new_record?
      @occurences_field.attributes = {:field_format => 'int', :default_value => '0', :is_filter => true}
      @occurences_field.save(false)
    end

    @trace_filter_field = ProjectCustomField.find_or_initialize_by_name('Backtrace filter')
    if @trace_filter_field.new_record?
      @trace_filter_field.attributes = {:field_format => 'text'}
      @trace_filter_field.save(false)
    end

    @repository_root_field = ProjectCustomField.find_or_initialize_by_name('Repository root')
    if @repository_root_field.new_record?
      @repository_root_field.attributes = {:field_format => 'string'}
      @repository_root_field.save(false)
    end

  end
end
