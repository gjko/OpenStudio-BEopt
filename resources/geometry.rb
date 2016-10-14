require "#{File.dirname(__FILE__)}/constants"

class Geometry

    def self.make_one_space_from_multiple_spaces(model, spaces)
      new_space = OpenStudio::Model::Space.new(model)
      spaces.each do |space|
        space.surfaces.each do |surface|
          if surface.adjacentSurface.is_initialized and surface.surfaceType.downcase == "wall"
            surface.adjacentSurface.get.remove
            surface.remove
          else
            surface.setSpace(new_space)
          end
        end
        space.remove
      end      
      return new_space
    end

    def self.make_polygon(*pts)
        p = OpenStudio::Point3dVector.new
        pts.each do |pt|
            p << pt
        end
        return p
    end
    
    def self.get_num_units(model, runner=nil)
        if not model.getBuilding.standardsNumberOfLivingUnits.is_initialized
            if !runner.nil?
                runner.registerError("Cannot determine number of building units; Building::standardsNumberOfLivingUnits has not been set.")
            end
            return nil
        end
        # FIXME: Update standardsNumberOfLivingUnits in SFA/MF geometry measures;
        # factor in zone multipliers when checking for consistency.
        num_units = model.getBuilding.standardsNumberOfLivingUnits.get
        # Check that this matches the number of unit specifications
        units_found = []
        model.getElectricEquipments.each do |ee|
            next if !ee.name.to_s.start_with?("unit=")
            ee.name.to_s.split("|").each do |data|
                next if !data.start_with?("unit=")
                vals = data.split("=")
                units_found << vals[1].to_i
            end
        end
        if num_units != units_found.size
            if !runner.nil?
                runner.registerError("Cannot determine number of building units; inconsistent number of units defined in the model.")
            end
            return nil
        end
        return num_units
    end
    
    def self.set_unit_beds_baths_spaces(model, unit_num, spaces_list, nbeds=nil, nbaths=nil)
        # Information temporarily stored in the name of a dummy ElectricEquipment object.
        # This method sets or updates the dummy object.
        if nbeds.nil?
          nbeds = "nil"
        end
        if nbaths.nil?
          nbaths = "nil"
        end
        
        str = "unit=#{unit_num}|bed=#{nbeds}|bath=#{nbaths}"
        spaces_list.each do |space|
            str += "|space=#{space.handle.to_s}"
        end
        
        # Update existing object?
        model.getElectricEquipments.each do |ee|
            next if !ee.name.to_s.start_with?("unit=#{unit_num}|")
            ee.setName(str)
            ee.electricEquipmentDefinition.setName(str)
            return
        end
        
        # No existing object, create a new one
        eed = OpenStudio::Model::ElectricEquipmentDefinition.new(model)
        eed.setName(str)
        sch = OpenStudio::Model::ScheduleRuleset.new(model, 0)
        sch.setName('empty_schedule')
        ee = OpenStudio::Model::ElectricEquipment.new(eed)
        ee.setName(str)
        ee.setSchedule(sch)
    end
    
    def self.get_unit_beds_baths_spaces(model, unit_num, runner=nil)
        # Retrieves information temporarily stored in the name of a dummy ElectricEquipment object.
        # Returns a vector with #beds, #baths, and a list of spaces
        nbeds = nil
        nbaths = nil
        spaces_list = nil
        
        model.getElectricEquipments.each do |ee|
            next if !ee.name.to_s.start_with?("unit=#{unit_num}|")
            ee.name.to_s.split("|").each do |data|
                if data.start_with?("bed=") and !data.end_with?("nil")
                    vals = data.split("=")
                    nbeds = vals[1].to_f
                elsif data.start_with?("bath=") and !data.end_with?("nil")
                    vals = data.split("=")
                    nbaths = vals[1].to_f
                elsif data.start_with?("space=")
                    vals = data.split("=")
                    space_handle_s = vals[1].to_s
                    space_found = false
                    model.getSpaces.each do |space|
                        next if space.handle.to_s != space_handle_s
                        if spaces_list.nil?
                            spaces_list = []
                        end
                        spaces_list << space
                        space_found = true
                        break # found space
                    end
                    if !runner.nil? and !space_found
                        runner.registerError("Could not find the space '#{space_handle_s}' associated with unit #{unit_num}.")
                        return [nil, nil, nil]
                    end
                end
            end
            break # found unit
        end
        return [nbeds, nbaths, spaces_list]
    end
    
    def self.rename_unit_spaces_zones(model, old_unit_num, new_unit_num)
        space_names_list = []
        model.getElectricEquipments.each do |ee|
            next if !ee.name.to_s.start_with?("unit=#{old_unit_num}|")
            new_name = ee.name.to_s.gsub("unit=#{old_unit_num}|", "unit=#{new_unit_num}|")
            ee.setName(new_name)
            ee.electricEquipmentDefinition.setName(new_name)
            ee.name.to_s.split("|").each do |data|
                if data.start_with?("space=")            
                    vals = data.split("=")
                    space_names_list << vals[1]
                end
            end
        end
        model.getSpaces.each do |space|
          space_names_list.each do |s|
            next if !space.name.to_s == s
            space.setName(space.name.to_s.gsub("unit #{old_unit_num}", "unit #{new_unit_num}"))
            thermal_zone = space.thermalZone.get
            thermal_zone.setName(thermal_zone.name.to_s.gsub("unit #{old_unit_num}", "unit #{new_unit_num}"))
          end
        end
    end
    
    def self.remove_unit(model, unit_num)
      model.getElectricEquipments.each do |ee|
        next if !ee.name.to_s.start_with?("unit=#{unit_num}|")
        ee.electricEquipmentDefinition.remove
      end
    end
    
    def self.get_unit_default_finished_space(unit_spaces, runner)
        # For the specified unit, chooses an arbitrary finished space on the lowest above-grade story.
        # If no above-grade finished spaces are available, reverts to an arbitrary below-grade finished space.
        space = nil
        # Get lowest above-grade space
        bldg_min_z = 100000
        unit_spaces.each do |s|
            next if self.space_is_below_grade(s)
            next if self.space_is_unfinished(s)
            space_min_z = self.getSurfaceZValues(s.surfaces).min + OpenStudio::convert(s.zOrigin,"m","ft").get
            next if space_min_z >= bldg_min_z
            bldg_min_z = space_min_z
            space = s
        end
        if space.nil?
            # Try below-grade space
            unit_spaces.each do |s|
                next if self.space_is_above_grade(s)
                next if self.space_is_unfinished(s)
                space = s
                break
            end
        end
        if space.nil?
            runner.registerError("Could not find a finished space for unit #{unit_num}.")
        end
        return space
    end
    
    # Returns all spaces in the model associated with a unit
    def self.get_all_unit_spaces(model, runner=nil)
        num_units = self.get_num_units(model, runner)
        if num_units.nil?
            return nil
        end
        all_unit_spaces = []
        (1..num_units).to_a.each do |unit_num|
            _nbeds, _nbaths, unit_spaces = self.get_unit_beds_baths_spaces(model, unit_num, runner)
            if unit_spaces.nil?
                return nil
            end
            unit_spaces.each do |unit_space|
                next if all_unit_spaces.include?(unit_space)
                all_unit_spaces << unit_space
            end
        end
        return all_unit_spaces
    end
    
    # Returns all spaces in the model not associated with a unit
    def self.get_all_common_spaces(model, runner=nil)
        return (model.getSpaces - self.get_all_unit_spaces(model, runner))
    end
    
    def self.get_floor_area_from_spaces(spaces, apply_multipliers=false, runner=nil)
        floor_area = 0
        spaces.each do |space|
            mult = 1.0
            if apply_multipliers
                mult = space.multiplier.to_f
            end
            floor_area += OpenStudio.convert(space.floorArea * mult, "m^2", "ft^2").get
        end
        if floor_area == 0 and not runner.nil?
            runner.registerError("Could not find any floor area.")
            return nil
        end
        return floor_area
    end

    def self.get_finished_floor_area_from_spaces(spaces, apply_multipliers=false, runner=nil)
        floor_area = 0
        spaces.each do |space|
            next if not self.space_is_finished(space)
            mult = 1.0
            if apply_multipliers
                mult = space.multiplier.to_f
            end
            floor_area += OpenStudio.convert(space.floorArea * mult,"m^2","ft^2").get
        end
        if floor_area == 0 and not runner.nil?
            runner.registerError("Could not find any finished floor area.")
            return nil
        end
        return floor_area
    end
    
    def self.get_above_grade_finished_floor_area_from_spaces(spaces, apply_multipliers=false, runner=nil)
      floor_area = 0
      spaces.each do |space|
        next if not (self.space_is_finished(space) and self.space_is_above_grade(space))
        mult = 1.0
        if apply_multipliers
            mult = space.multiplier.to_f
        end
        floor_area += OpenStudio.convert(space.floorArea * mult,"m^2","ft^2").get
      end
      if floor_area == 0 and not runner.nil?
          runner.registerError("Could not find any above-grade finished floor area.")
          return nil
      end
      return floor_area      
    end    
    
    def self.get_above_grade_finished_volume_from_spaces(spaces, apply_multipliers=false, runner=nil)
      volume = 0
      spaces.each do |space|
        next if not (self.space_is_finished(space) and self.space_is_above_grade(space))
        mult = 1.0
        if apply_multipliers
            mult = space.multiplier.to_f
        end
        volume += OpenStudio.convert(space.floorArea * self.space_height(space) * mult,"m^2","ft^2").get
      end
      if volume == 0 and not runner.nil?
          runner.registerError("Could not find any above-grade finished volume.")
          return nil
      end
      return volume    
    end
    
    def self.get_window_area_from_spaces(spaces, apply_multipliers=false)
      window_area = 0
      spaces.each do |space|
        mult = 1.0
        if apply_multipliers
            mult = space.multiplier.to_f
        end
        space.surfaces.each do |surface|
          surface.subSurfaces.each do |subsurface|
            next if subsurface.subSurfaceType.downcase != "fixedwindow"
            window_area += OpenStudio::convert(subsurface.grossArea * mult,"m^2","ft^2").get
          end
        end
      end
      return window_area
    end
    
    # Calculates the space height as the max z coordinate minus the min z coordinate
    def self.space_height(space)
        zvalues = self.getSurfaceZValues(space.surfaces)
        minz = zvalues.min
        maxz = zvalues.max
        return maxz - minz
    end
    
    def self.get_building_height(spaces)
      minzs = []
      maxzs = []
      spaces.each do |space|
        zvalues = self.getSurfaceZValues(space.surfaces)
        minzs << zvalues.min + OpenStudio::convert(space.zOrigin,"m","ft").get
        maxzs << zvalues.max + OpenStudio::convert(space.zOrigin,"m","ft").get
      end
      return maxzs.max - minzs.min
    end
    
    # FIXME: Switch to using StandardsNumberOfStories and StandardsNumberOfAboveGroundStories instead
    def self.get_building_stories(spaces)
      space_min_zs = []
      spaces.each do |space|
        next if not self.space_is_finished(space)
        surfaces_min_zs = []
        space.surfaces.each do |surface|
          zvalues = self.getSurfaceZValues([surface])
          surfaces_min_zs << zvalues.min + OpenStudio::convert(space.zOrigin,"m","ft").get
        end
        space_min_zs << surfaces_min_zs.min
      end
      return space_min_zs.uniq.length
    end
    
    # Calculates the surface height as the max z coordinate minus the min z coordinate
    def self.surface_height(surface)
        zvalues = self.getSurfaceZValues([surface])
        minz = zvalues.min
        maxz = zvalues.max
        return maxz - minz
    end
    
    def self.zone_is_finished(zone)
        # FIXME: Ugly hack until we can get finished zones from OS
        if zone.name.to_s.start_with?(Constants.LivingZone) or zone.name.to_s.start_with?(Constants.FinishedBasementZone) or zone.name.to_s.include?("Story") # URBANopt hack: zone.name.to_s.include? "Story" ensures always finished zone
            return true
        end
        return false
    end
    
    # Returns true if all spaces in zone are fully above grade
    def self.zone_is_above_grade(zone)
      spaces_are_above_grade = []
      zone.spaces.each do |space|
        spaces_are_above_grade << self.space_is_above_grade(space)
      end
      if spaces_are_above_grade.all?
        return true
      end
      return false
    end

    # Returns true if all spaces in zone are either fully or partially below grade
    def self.zone_is_below_grade(zone)
      return !self.zone_is_above_grade(zone)
    end       
    
    def self.get_finished_above_and_below_grade_zones(thermal_zones)
      finished_living_zones = []
      finished_basement_zones = []
      thermal_zones.each do |thermal_zone|
        next unless self.zone_is_finished(thermal_zone)
        if self.zone_is_above_grade(thermal_zone)
          finished_living_zones << thermal_zone
        elsif self.zone_is_below_grade(thermal_zone)
          finished_basement_zones << thermal_zone
        end
      end
      return finished_living_zones, finished_basement_zones
    end
    
    def self.get_thermal_zones_from_spaces(spaces)
      thermal_zones = []
      spaces.each do |space|
        next unless space.thermalZone.is_initialized
        unless thermal_zones.include? space.thermalZone.get
          thermal_zones << space.thermalZone.get
        end
      end
      return thermal_zones
    end
    
    def self.get_building_type(model)
      building_type = nil
      unless model.getBuilding.standardsBuildingType.empty?
        building_type = model.getBuilding.standardsBuildingType.get.downcase
      end
      return building_type
   end
    
    def self.space_is_unfinished(space)
        return !self.space_is_finished(space)
    end
    
    def self.space_is_finished(space)
        if space.thermalZone.is_initialized
            return self.zone_is_finished(space.thermalZone.get)
        end
        return false
    end
    
    # Returns true if space is fully above grade
    def self.space_is_above_grade(space)
        return !self.space_is_below_grade(space)
    end
    
    # Returns true if space is either fully or partially below grade
    def self.space_is_below_grade(space)
        space.surfaces.each do |surface|
            next if surface.surfaceType.downcase != "wall"
            if surface.isGroundSurface
                return true
            end
        end
        return false
    end 
    
    def self.space_has_roof(space)
        space.surfaces.each do |surface|
            next if surface.surfaceType.downcase != "roofceiling"
            next if surface.outsideBoundaryCondition.downcase != "outdoors"
            next if surface.tilt == 0
            return true
        end
        return false
    end
    
    def self.space_below_is_finished(space, model)
        space.surfaces.each do |surface|
            next if surface.surfaceType.downcase != "floor"
            next if not surface.adjacentSurface.is_initialized
            next if not surface.adjacentSurface.get.space.is_initialized
            adjacent_space = surface.adjacentSurface.get.space.get
            next if not self.space_is_finished(adjacent_space)
            return true
        end
        return false
    end

    def self.get_space_from_string(spaces, space_s, runner=nil)
        if space_s == Constants.Auto
            return self.get_unit_default_finished_space(spaces, runner)
        end
        space = nil
        spaces.each do |s|
            if s.name.to_s == space_s
                space = s
                break
            end
        end
        if space.nil? and !runner.nil?
            runner.registerError("Could not find space with the name '#{space_s}'.")
        end
        return space
    end

    def self.get_thermal_zone_from_string(zones, thermalzone_s, runner=nil)
        thermal_zone = nil
        zones.each do |tz|
            if tz.name.to_s == thermalzone_s
                thermal_zone = tz
                break
            end
        end
        if thermal_zone.nil? and !runner.nil?
            runner.registerError("Could not find zone with the name '#{thermalzone_s}'.")
        end
        return thermal_zone
    end

    # Return an array of x values for surfaces passed in. The values will be relative to the parent origin. This was intended for spaces.
    def self.getSurfaceXValues(surfaceArray)
        xValueArray = []
        surfaceArray.each do |surface|
            surface.vertices.each do |vertex|
                xValueArray << OpenStudio.convert(vertex.x, "m", "ft").get
            end
        end
        return xValueArray
    end

    # Return an array of y values for surfaces passed in. The values will be relative to the parent origin. This was intended for spaces.
    def self.getSurfaceYValues(surfaceArray)
        yValueArray = []
        surfaceArray.each do |surface|
            surface.vertices.each do |vertex|
                yValueArray << OpenStudio.convert(vertex.y, "m", "ft").get
            end
        end
        return yValueArray
    end
    
    # Return an array of z values for surfaces passed in. The values will be relative to the parent origin. This was intended for spaces.
    def self.getSurfaceZValues(surfaceArray)
        zValueArray = []
        surfaceArray.each do |surface|
            surface.vertices.each do |vertex|
                zValueArray << OpenStudio.convert(vertex.z, "m", "ft").get
            end
        end
        return zValueArray
    end

    def self.get_z_origin_for_zone(zone)
      z_origins = []
      zone.spaces.each do |space|
        z_origins << space.zOrigin
      end
      return z_origins.min
    end
    
    # Takes in a list of spaces and returns the average space height
    def self.spaces_avg_height(spaces)
        sum_height = 0
        spaces.each do |space|
            sum_height += self.space_height(space)
        end
        return sum_height/spaces.size
    end
    
    # Takes in a list of surfaces and returns the total gross area
    def self.calculate_total_area_from_surfaces(surfaces)
        total_area = 0
        surfaces.each do |surface|
            total_area += OpenStudio.convert(surface.grossArea, "m^2", "ft^2").get
        end
        return total_area
    end
    
    # Takes in a list of spaces and returns the total wall area
    def self.calculate_wall_area(spaces, apply_multipliers=false)
        wall_area = 0
        spaces.each do |space|
            mult = 1.0
            if apply_multipliers
                mult = space.multiplier.to_f
            end
            space.surfaces.each do |surface|
                next if surface.surfaceType.downcase != "wall"
                wall_area += OpenStudio.convert(surface.grossArea * mult, "m^2", "ft^2").get
            end
        end
        return wall_area
    end
    
    def self.calculate_exterior_wall_area(spaces, apply_multipliers=false)
        wall_area = 0
        spaces.each do |space|
            mult = 1.0
            if apply_multipliers
                mult = space.multiplier.to_f
            end
            space.surfaces.each do |surface|
                next if surface.surfaceType.downcase != "wall"
                next if surface.outsideBoundaryCondition.downcase != "outdoors"
                wall_area +=  OpenStudio.convert(surface.grossArea * mult, "m^2", "ft^2").get
            end
        end
        return wall_area
    end    
    
    def self.calculate_avg_roof_pitch(spaces)
        sum_tilt = 0
        num_surf = 0
        spaces.each do |space|
            space.surfaces.each do |surface|
                if surface.surfaceType.downcase == "roofceiling"
                    sum_tilt += surface.tilt
                    num_surf += 1
                end
            end
        end
        if num_surf == 0
            return nil
        end
        return sum_tilt/num_surf.to_f*180.0/3.14159
    end
    
    # Checks if the surface is between finished and unfinished space
    def self.is_interzonal_surface(surface)
        if surface.outsideBoundaryCondition.downcase != "surface" or not surface.space.is_initialized or not surface.adjacentSurface.is_initialized
            return false
        end
        adjacent_surface = surface.adjacentSurface.get
        if not adjacent_surface.space.is_initialized
            return false
        end
        if self.space_is_finished(surface.space.get) == self.space_is_finished(adjacent_surface.space.get)
            return false
        end
        return true
    end
    
    # Takes in a list of ground exposed floor surfaces for which to calculate the perimeter; 
    # checks for edges shared by a ground exposed floor and 1) exterior exposed or 2) interzonal wall.
    # FIXME: test on buildings with multiple foundations
    def self.calculate_perimeter(model, ground_floor_surfaces, has_foundation_walls=false)

        perimeter = 0

        # Get ground edges
        if not has_foundation_walls
            # Use edges from floor surface
            ground_edge_hash = self.get_edges_for_surfaces(ground_floor_surfaces)
        else
            # Use top edges from foundation walls instead
            surfaces = []
            ground_floor_surfaces.each do |ground_floor_surface|
                next if not ground_floor_surface.space.is_initialized
                foundation_space = ground_floor_surface.space.get
                foundation_space.surfaces.each do |surface|
                    next if not surface.surfaceType.downcase == "wall"
                    next if surfaces.include? surface
                    surfaces << surface
                end
            end
            ground_edge_hash = self.get_edges_for_surfaces(surfaces, true)
        end
        
        # Get bottom edges of exterior exposed walls or interzonal walls
        surfaces = []
        model.getSurfaces.each do |surface|
            next if not surface.surfaceType.downcase == "wall"
            next if not (surface.outsideBoundaryCondition.downcase == "outdoors" or self.is_interzonal_surface(surface))
            surfaces << surface
        end
        model_edge_hash = self.get_edges_for_surfaces(surfaces)
        
        # check edges for matches
        ground_edge_hash.each do |k1,v1|
            model_edge_hash.each do |k2,v2|
                # see if edges have same geometry
                # FIXME: This doesn't handle overlapping edges
                next if not ((v1[0] == v2[1] and v1[1] == v2[0]) or (v1[0] == v2[0] and v1[1] == v2[1]))
                point_one = OpenStudio::Point3d.new(v1[0][0],v1[0][1],v1[0][2])
                point_two = OpenStudio::Point3d.new(v1[1][0],v1[1][1],v1[1][2])
                length = OpenStudio::Vector3d.new(point_one - point_two).length
                perimeter += length
            end
        end
    
        return OpenStudio.convert(perimeter, "m", "ft").get
    end
    
    def self.get_edges_for_surfaces(surfaces, use_top_edge=false)
        edge_hash = {}
        edge_counter = 0
        surfaces.each do |surface|
            # ensure we only process bottom or top edge of wall surfaces
            if use_top_edge
                matchz = self.getSurfaceZValues([surface]).max
            else
                matchz = self.getSurfaceZValues([surface]).min
            end
            # get vertices
            vertex_hash = {}
            vertex_counter = 0
            surface.vertices.each do |vertex|
                next if (OpenStudio.convert(vertex.z, "m", "ft").get - matchz).abs > 0.0001
                vertex_counter += 1
                vertex_hash[vertex_counter] = [vertex.x + surface.space.get.xOrigin,
                                               vertex.y + surface.space.get.yOrigin,
                                               vertex.z + surface.space.get.zOrigin]
            end
            # make edges
            counter = 0
            vertex_hash.each do |k,v|
                edge_counter += 1
                counter += 1
                if vertex_hash.size != counter
                    edge_hash[edge_counter] = [v,vertex_hash[counter+1],surface,surface.outsideBoundaryCondition,surface.surfaceType]
                elsif vertex_hash.size > 2 # different code for wrap around vertex (if > 2 vertices)
                    edge_hash[edge_counter] = [v,vertex_hash[1],surface,surface.outsideBoundaryCondition,surface.surfaceType]
                end
            end
        end
        return edge_hash
    end
    
    def self.get_crawl_spaces(spaces)
        crawl_spaces = []
        spaces.each do |space|
            next if self.space_is_above_grade(space)
            next if self.space_height(space) >= Constants.MinimumBasementHeight
            crawl_spaces << space
        end
        return crawl_spaces
    end
    
    def self.get_finished_spaces(spaces)
        finished_spaces = []
        spaces.each do |space|
            next if self.space_is_unfinished(space)
            finished_spaces << space
        end
        return finished_spaces
    end
    
    def self.get_finished_basement_spaces(spaces)
        finished_basement_spaces = []
        spaces.each do |space|
            next if self.space_is_unfinished(space)
            next if self.space_is_above_grade(space)
            next if self.space_height(space) < Constants.MinimumBasementHeight
            finished_basement_spaces << space
        end
        return finished_basement_spaces
    end
    
    def self.get_unfinished_basement_spaces(spaces)
        unfinished_basement_spaces = []
        spaces.each do |space|
            next if self.space_is_finished(space)
            next if self.space_is_above_grade(space)
            next if self.space_height(space) < Constants.MinimumBasementHeight
            unfinished_basement_spaces << space
        end
        return unfinished_basement_spaces
    end
   
    def self.get_unfinished_attic_spaces(spaces, model)
        unfinished_attic_spaces = []
        spaces.each do |space|
            next if self.space_is_finished(space)
            next if not self.space_has_roof(space)
            next if not self.space_below_is_finished(space, model)
            unfinished_attic_spaces << space
        end
        return unfinished_attic_spaces
    end
    
    def self.get_finished_attic_spaces(spaces, model)
        finished_attic_spaces = []
        spaces.each do |space|
            next if self.space_is_unfinished(space)
            next if not self.space_has_roof(space)
            next if not self.space_below_is_finished(space, model)
            finished_attic_spaces << space
        end
        return finished_attic_spaces
    end
    
    def self.get_garage_spaces(spaces, model) #unfinished, above grade spaces without a finished space below
        garage_spaces = []
        spaces.each do |space|
            next if self.space_is_finished(space)
            next if self.space_is_below_grade(space)
            next if self.space_below_is_finished(space, model)
            next if self.space_has_roof(space)
            garage_spaces << space
        end
        return garage_spaces
    end
    
    def self.get_non_attic_unfinished_roof_spaces(spaces, model)
        non_attic_unfinished_roof_spaces = []
        spaces.each do |space|
            next if self.space_is_finished(space)
            next if not self.space_has_roof(space)
            next if self.space_below_is_finished(space, model)
            non_attic_unfinished_roof_spaces << space
        end
        return non_attic_unfinished_roof_spaces
    end
    
    def self.get_facade_for_surface(surface)
        tol = 0.001
        n = surface.outwardNormal
        facade = nil
        if (n.z).abs < tol
            if (n.x).abs < tol and (n.y + 1).abs < tol
                facade = Constants.FacadeFront
            elsif (n.x - 1).abs < tol and (n.y).abs < tol
                facade = Constants.FacadeRight
            elsif (n.x).abs < tol and (n.y - 1).abs < tol
                facade = Constants.FacadeBack
            elsif (n.x + 1).abs < tol and (n.y).abs < tol
                facade = Constants.FacadeLeft
            end
        elsif
            if (n.x).abs < tol and n.y < 0
                facade = Constants.FacadeFront
            elsif n.x > 0 and (n.y).abs < tol
                facade = Constants.FacadeRight
            elsif (n.x).abs < tol and n.y > 0
                facade = Constants.FacadeBack
            elsif n.x < 0 and (n.y).abs < tol
                facade = Constants.FacadeLeft
            end
        end
        return facade
    end
    
    def self.get_surface_length(surface)
        xvalues = self.getSurfaceXValues([surface])
        yvalues = self.getSurfaceYValues([surface])
        xrange = xvalues.max - xvalues.min
        yrange = yvalues.max - yvalues.min
        if xrange > yrange
            return xrange
        end
        return yrange
   end
   
   def self.get_surface_height(surface) 
        zvalues = self.getSurfaceZValues([surface])
        zrange = zvalues.max - zvalues.min
        return zrange
   end
   
   def self.is_gable_wall(surface)
        if (surface.surfaceType.downcase != "wall" or surface.outsideBoundaryCondition.downcase != "outdoors")
            return false
        end
        if surface.vertices.size != 3
            return false
        end
        if not surface.space.is_initialized
            return false
        end
        space = surface.space.get
        if not self.space_has_roof(space)
            return false
        end
        return true
   end
   
   def self.is_rectangular_wall(surface)
        if (surface.surfaceType.downcase != "wall" or surface.outsideBoundaryCondition.downcase != "outdoors")
            return false
        end
        if surface.vertices.size != 4
            return false
        end        
        xvalues = self.getSurfaceXValues([surface])
        yvalues = self.getSurfaceYValues([surface])
        zvalues = self.getSurfaceZValues([surface])
        if not ((xvalues.uniq.size == 1 and yvalues.uniq.size == 2) or
                (xvalues.uniq.size == 2 and yvalues.uniq.size == 1))
            return false
        end
        if not zvalues.uniq.size == 2
            return false
        end
        return true
   end
   
  def self.get_closest_neighbor_distance(model)
    house_points = []
    neighbor_points = []
    model.getSurfaces.each do |surface|
      next unless surface.surfaceType.downcase == "wall"
      surface.vertices.each do |vertex|
        house_points << OpenStudio::Point3d.new(vertex)
      end
    end
    model.getShadingSurfaces.each do |shading_surface|
      next unless shading_surface.name.to_s.downcase.include? "neighbor"
      shading_surface.vertices.each do |vertex|
        neighbor_points << OpenStudio::Point3d.new(vertex)
      end
    end
    neighbor_offsets = []
    house_points.each do |house_point|
      neighbor_points.each do |neighbor_point|
        neighbor_offsets << OpenStudio::getDistance(house_point, neighbor_point)
      end
    end
    if neighbor_offsets.empty?
      return 0
    end    
    return OpenStudio::convert(neighbor_offsets.min,"m","ft").get
  end
    
end