# External
require "sinatra/base"

require_relative "./fastfile-parser/fastfile_parser"

# Internal
require_relative "services/config_data_sources/json_project_data_source"
require_relative "services/config_service"
require_relative "services/worker_service"
require_relative "services/user_service"
require_relative "services/data_sources/json_user_data_source"
require_relative "services/data_sources/json_build_data_source"
require_relative "services/code_hosting_sources/git_hub_source"

require_relative "workers/refresh_config_data_sources_worker"

require_relative "shared/logging_module"
require_relative "shared/fastlane_ci_error" # TODO: move somewhere else

# All things fastlane ci related go in this module
module FastlaneCI
  # Used to use the same layout file across all views
  # https://stackoverflow.com/questions/26080599/sinatra-method-to-set-layout
  def self.default_layout
    "../../../features/global/layout".to_sym
  end

  # Our CI app main class
  class FastlaneApp < Sinatra::Base
    include FastlaneCI::Logging
    Thread.current[:thread_id] = "main"

    get "/" do
      if session[:user]
        redirect("/dashboard")
      else
        redirect("/login")
      end
    end

    get "/favico.ico" do
      "nope"
    end

    # Setup the fastlane.ci GitRepoConfig
    ci_config_repo = GitRepoConfig.new(
      id: "fastlane-ci-config",
      git_url: ENV["FASTLANE_CI_REPO_URL"],
      description: "Contains the fastlane.ci configuration",
      name: "fastlane ci",
      hidden: true
    )

    # Get the path to where we store fastlane.ci configuration
    ci_config_git_repo_path = ci_config_repo.local_repo_path

    # Create JSON data sources from the configuration git repo
    user_data_source = JSONUserDataSource.new(json_folder_path: ci_config_git_repo_path)
    build_data_source = JSONBuildDataSource.new(json_folder_path: ci_config_git_repo_path)

    # Start up a UserService from our JSONUserDataSource
    USER_SERVICE = FastlaneCI::UserService.new(user_data_source: user_data_source)

    # Start up the BuildService
    BUILD_SERVICE = FastlaneCI::BuildService.new(build_data_source: build_data_source)

    # Find our fastlane.ci system user
    @ci_user = USER_SERVICE.login(email: ENV["FASTLANE_CI_USER"], password: ENV["FASTLANE_CI_PASSWORD"], ci_config_repo: ci_config_repo)

    # Start our project data source, TODO: this should be accessed through a ProjectDataService
    PROJECT_DATA_SOURCE = FastlaneCI::JSONProjectDataSource.new(git_repo_config: ci_config_repo, user: @ci_user)

    # Going ot start our workers
    @worker_service = FastlaneCI::WorkerService.new

    # Grab a config service that is configured for the CI user
    @ci_user_config_service = FastlaneCI::ConfigService.new(ci_user: @ci_user)

    # Iterate through all provider credentials and their projects and start a worker for each project
    number_of_workers_started = 0
    @ci_user.provider_credentials.each do |provider_credential|
      projects = @ci_user_config_service.projects(provider_credential: provider_credential)
      projects.each do |project|
        @worker_service.start_worker_for_provider_credential_and_config(
          project: project,
          provider_credential: provider_credential
        )
        number_of_workers_started += 1
      end
    end
    puts("Seems like no workers were started to monitor your projects") if number_of_workers_started == 0 # TODO: use logger

    # Initialize the workers
    # For now, we're not using a fancy framework that adds multiple heavy dependencies
    # including a database, etc.
    FastlaneCI::RefreshConfigDataSourcesWorker.new
  end
end
