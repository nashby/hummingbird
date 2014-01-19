require_relative 'entities.rb'
require 'message_formatter'

class API_v1 < Grape::API
  version 'v1', using: :path, format: :json, vendor: 'hummingbird'
  formatter :json, lambda {|object, env| MultiJson.dump(object) }
  rescue_from ActiveRecord::RecordNotFound

  helpers do
    def warden; env['warden']; end
    def current_user
      return env['current_user'] if env['current_user']
      if params[:auth_token] or cookies[:auth_token]
        user = User.find_by_authentication_token(params[:auth_token] || cookies[:auth_token])
        if user.nil?
          error!("Invalid authentication token", 401)
        end
        env['current_user'] = user
      else
        nil
      end
    end
    def user_signed_in?
      not current_user.nil?
    end
    def authenticate_user!
      if user_signed_in?
        return true
      else
        error!("401 Unauthenticated", 401)
      end
    end
    def current_ability
      @current_ability ||= Ability.new(current_user)
    end
    def find_user(id)
      begin
        if id == "me" and user_signed_in?
          current_user
        else
          User.find(id)
        end
      rescue
        error!("404 Not Found", 404)
      end
    end

    def present_watchlist(w, rating_type, title_language_preference)
      {
        id: w.id,
        episodes_watched: w.episodes_watched,
        last_watched: w.last_watched || w.updated_at,
        rewatched_times: w.rewatch_count,
        notes: w.notes,
        notes_present: (w.notes and w.notes.strip.length > 0),
        status: w.status.downcase.gsub(' ', '-'),
        private: w.private,
        rewatching: w.rewatching,
        anime: present_anime(w.anime, title_language_preference, false),
        rating: {
          type: rating_type,
          value: w.rating
        }
      }
    end

    def present_miniuser(user)
      {
        name: user.name,
        url: "http://hummingbird.me/users/#{user.name}",
        avatar: user.avatar.url(:thumb),
        avatar_small: user.avatar.url(:thumb_small),
        nb: user.ninja_banned?
      }
    end

    def present_anime(anime, title_language_preference, include_genres=true)
      if anime
        json = {
          slug: anime.slug,
          status: anime.status,
          url: "http://hummingbird.me/anime/#{anime.slug}",
          title: anime.canonical_title(title_language_preference),
          alternate_title: anime.alternate_title(title_language_preference),
          episode_count: anime.episode_count,
          cover_image: anime.poster_image_thumb,
          synopsis: anime.synopsis,
          show_type: anime.show_type
        }
        if include_genres
          json[:genres] = anime.genres.map {|x| {name: x.name} }
        end
        json
      else
        {}
      end
    end

    def present_story(story, current_user, title_language_preference)
      json = {
        id: story.id,
        story_type: story.story_type,
        user: present_miniuser(story.user),
        updated_at: story.updated_at,
      }
      if story.story_type == "comment"
        json[:self_post] = (story.target == story.user)
        json[:poster] = present_miniuser(story.target)
      elsif story.story_type == "media_story"
        json[:media] = present_anime(story.target, title_language_preference)
      end
      substories = story.substories
      json[:substories_count] = substories.length
      json[:substories] = substories.map do |substory|
        subjson = {
          id: substory.id,
          substory_type: substory.substory_type,
          created_at: substory.created_at
        }
        if substory.substory_type == "followed"
          subjson[:followed_user] = present_miniuser(substory.target)
        elsif %w[liked_quote submitted_quote].include? substory.substory_type
          quote = substory.target
          subjson[:quote] = {
            content: quote.content,
            character_name: quote.character_name
          }
        elsif substory.substory_type == "watchlist_status_update"
          subjson[:new_status] = (substory.data["new_status"] || "Currently Watching").downcase.gsub(' ', '_')
        elsif substory.substory_type == "watched_episode"
          subjson[:episode_number] = substory.data["episode_number"]
          subjson[:service] = substory.data["service"]
        elsif substory.substory_type == "comment"
          if substory.data["formatted_comment"].nil?
            formatted_comment = MessageFormatter.format_message substory.data["comment"]
            substory.data["formatted_comment"] = formatted_comment
            substory.save
          end
          subjson[:comment] = substory.data["formatted_comment"]
        end
        if current_user and ((substory.user_id == current_user.id) or (story.user_id == current_user.id) or current_user.admin?)
          subjson[:permissions] = {destroy: true}
        else
          subjson[:permissions] = {}
        end
        subjson
      end
      json
    end
  end

  desc "Return the user's timeline"
  params do
    optional :page, type: Integer
  end
  get '/timeline' do
    if user_signed_in?
      NewsFeed.new(current_user).fetch(params[:page]).map {|x| present_story(x, current_user, current_user.title_language_preference) }
    else
      []
    end
  end

  resource :users do
    desc "Return authentication code"
    params do
      optional :username, type: String
      optional :email, type: String
      requires :password, type: String
    end
    post '/authenticate' do
      user = nil
      if params[:username]
        user = User.where("LOWER(name) = ?", params[:username]).first
      elsif params[:email]
        user = User.where("LOWER(email) = ?", params[:email]).first
      end
      if user.nil? or (not user.valid_password? params[:password])
        error!("Invalid credentials", 401)
      end
      user.reset_authentication_token! if user.authentication_token.nil?
      return user.authentication_token
    end

    desc "Return the current user."
    params do
      requires :username, type: String
    end
    get ':username' do
      user = find_user(params[:username])
      json = {
        name: user.name,
        avatar: user.avatar.url(:thumb),
        cover_image: user.cover_image.url(:thumb),
        about: user.about,
        bio: user.bio,
        karma: 0,
        life_spent_on_anime: user.life_spent_on_anime,
        show_adult_content: !user.sfw_filter?,
        title_language_preference: user.title_language_preference,
        last_library_update: user.last_library_update,
        online: user.online?,
        following: (user_signed_in? and user.followers.include?(current_user))
      }
      if user == current_user
        json["email"] = user.email
      end
      json
    end

    desc "Return the entries in a user's library under a specific status."
    params do
      requires :user_id, type: String
      optional :status, type: String
      optional :page, type: Integer
      optional :title_language_preference, type: String
      optional :include_mal_id, type: String
    end
    get ':user_id/library' do
      if params[:page] and params[:page] > 1
        return []
      end

      user = find_user(params[:user_id])
      status = Watchlist.status_parameter_to_status(params[:status])

      watchlists = user.watchlists.includes(:anime)
      watchlists = watchlists.where(status: status) if status
      watchlists = watchlists.where(private: false) if user != current_user

      title_language_preference = params[:title_language_preference]
      if title_language_preference.nil? and current_user
        title_language_preference = current_user.title_language_preference
      end
      title_language_preference ||= "canonical"

      rating_type = user.star_rating? ? "advanced" : "simple"

      watchlists.map {|w| present_watchlist(w, rating_type, title_language_preference) }
    end

    desc "Returns the user's feed."
    params do
      requires :user_id, type: String
      optional :page, type: Integer
    end
    get ":user_id/feed" do
      user = find_user(params[:user_id])

      # Find stories to display.
      stories = user.stories.for_user(current_user).order('updated_at DESC').includes(:substories, :user, :target).page(params[:page]).per(20)

      stories.map {|x| present_story(x, current_user, current_user.try(:title_language_preference) || "canonical") }
    end

    desc "Delete a substory from the user's feed."
    params do
      requires :user_id, type: String
      requires :substory_id, type: Integer
    end
    post ":user_id/feed/remove" do
      begin
        substory = Substory.find params[:substory_id]
      rescue
        return true
      end
      if current_user and (current_user.admin? or (current_user.id == substory.user_id) or (current_user.id == substory.story.user_id))
        substory.destroy
        return true
      else
        return false
      end
    end
  end

  resource :libraries do
    desc "Remove an entry"
    params do
      requires :anime_slug, type: String
    end
    post ':anime_slug/remove' do
      authenticate_user!

      anime = Anime.find(params["anime_slug"])
      watchlist = Watchlist.find_or_create_by_anime_id_and_user_id(anime.id, current_user.id)
      watchlist.destroy
      true
    end

    desc "Update a specific anime's details in a user's library."
    params do
      requires :anime_slug, type: String
      optional :increment_episodes, type: String
      optional :rewatching, type: String
    end
    post ':anime_slug' do
      authenticate_user!

      anime = Anime.find(params["anime_slug"])
      watchlist = Watchlist.find_or_create_by_anime_id_and_user_id(anime.id, current_user.id)

      # Update status.
      if params[:status]
        status = Watchlist.status_parameter_to_status(params[:status])
        if watchlist.status != status
          # Create an action if the status was changed.
          Substory.from_action({
            user_id: current_user.id,
            action_type: "watchlist_status_update",
            anime_id: anime.slug,
            old_status: watchlist.status,
            new_status: status,
            time: Time.now
          })
        end
        watchlist.status = status if Watchlist.valid_statuses.include? status
        if status == "Completed"
          # Mark all episodes as viewed when the show is "Completed".
          watchlist.update_episode_count (watchlist.anime.episode_count || 0)
        end
      end

      # Update privacy.
      if params[:privacy]
        if params[:privacy] == "private"
          watchlist.private = true
        elsif params[:privacy] == "public"
          watchlist.private = false
        end
      end

      # Update rewatched_times.
      if params[:rewatched_times]
        watchlist.update_rewatched_times params[:rewatched_times]
      end

      # Update notes.
      if params[:notes]
        watchlist.notes = params[:notes]
      end

      # Update episode count.
      if params[:episodes_watched]
        watchlist.update_episode_count params[:episodes_watched]
      end

      # Update "rewatching" status.
      if params[:rewatching]
        watchlist.rewatching = (params[:rewatching] == "true")
      end

      if params[:increment_episodes] and params[:increment_episodes] == "true"
        watchlist.status = "Currently Watching"
        watchlist.update_episode_count((watchlist.episodes_watched||0)+1)
        if current_user.neon_alley_integration? and Anime.neon_alley_ids.include? anime.id
          service = "neon_alley"
        else
          service = nil
        end
        Substory.from_action({
          user_id: current_user.id,
          action_type: "watched_episode",
          anime_id: anime.slug,
          episode_number: watchlist.episodes_watched,
          service: service
        })
        if watchlist.status == "Completed"
          Substory.from_action({
            user_id: current_user.id,
            action_type: "watchlist_status_update",
            anime_id: anime.slug,
            old_status: "Currently Watching",
            new_status: "Completed",
            time: Time.now + 5.seconds
          })
        end
      end

      title_language_preference = params[:title_language_preference]
      if title_language_preference.nil? and current_user
        title_language_preference = current_user.title_language_preference
      end
      title_language_preference ||= "canonical"
      rating_type = current_user.star_rating? ? "advanced" : "simple"

      result = watchlist.save

      # Update rating.
      if params[:rating]
        library_entry = LibraryEntry.where(user_id: current_user.id,
                                           anime_id: anime.id).first

        if library_entry.rating == params[:rating].to_f
          library_entry.rating = nil
        else
          library_entry.rating = [ [0, params[:rating].to_f].max, 5].min
        end
        result = result and library_entry.save
      end

      if result
        present_watchlist(watchlist.reload, rating_type, title_language_preference)
      else
        return false
      end
    end
  end

  resource :anime do
    desc "Return an anime"
    params do
      requires :id, type: String, desc: "anime ID"
      optional :title_language_preference, type: String
    end
    get ':id' do
      anime = Anime.find(params[:id])

      title_language_preference = params[:title_language_preference]
      if title_language_preference.nil? and current_user
        title_language_preference = current_user.title_language_preference
      end
      title_language_preference ||= "canonical"

      present_anime(anime, title_language_preference)
    end

    desc "Returns similar anime."
    params do
      requires :id, type: String, desc: "anime ID"
      optional :limit, type: Integer, desc: "number of results (max/default 20)"
    end
    get ':id/similar' do
      anime = Anime.find(params[:id])
      similar_anime = []
      similar_json = JSON.load(open("http://app.vikhyat.net/anime_safari/related/#{anime.id}")).sort_by {|x| -x["sim"] }
      similar_json.each do |similar|
        sim = Anime.find_by_id(similar["id"])
        similar_anime.push(sim) if sim and similar_anime.length < (params[:limit] || 20)
      end
      similar_anime.map {|x| {id: x.slug, title: x.canonical_title, alternate_title: x.alternate_title, genres: x.genres.map {|x| {name: x.name} }, cover_image: x.poster_image.url(:large), url: anime_url(x)} }
    end
  end

  desc "Anime search API endpoint"
  params do
    requires :query, type: String, desc: "query string"
  end
  get '/search/anime' do
    anime = Anime.accessible_by(current_ability).includes(:genres)
    results = anime.simple_search_by_title(params[:query]).limit(5)
    if results.length == 0
      results = anime.fuzzy_search_by_title(params[:query]).limit(5)
    end

    title_language_preference = current_user.try(:title_language_preference) || "canonical"

    results.map {|x| present_anime(x, title_language_preference, false) }
  end
end
