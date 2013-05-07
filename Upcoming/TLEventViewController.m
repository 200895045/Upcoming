//
//  ECViewController.m
//  EventCollectionView
//
//  Created by Brendan Lynch on 13-04-17.
//  Copyright (c) 2013 Teehan+Lax. All rights reserved.
//

#import "TLEventViewController.h"
#import "TLBackgroundGradientView.h"
#import "EKEventManager.h"
#import "TLHourCell.h"
#import "TLAppDelegate.h"
#import "TLRootViewController.h"
#import "TLHourSupplementaryView.h"
#import "TLEventSupplementaryView.h"
#import "TLEventViewModel.h"

static NSString *kCellIdentifier = @"Cell";
static NSString *kHourSupplementaryViewIdentifier = @"HourView";
static NSString *kEventSupplementaryViewIdentifier = @"EventView";


@interface TLEventViewController ()

@property (nonatomic, assign) CGPoint location;
@property (nonatomic, assign) BOOL touch;
@property (nonatomic, strong) TLBackgroundGradientView *backgroundGradientView;

@property (nonatomic, strong) NSIndexPath *indexPathUnderFinger;
@property (nonatomic, strong) EKEvent *eventUnderFinger;

@property (nonatomic, strong) NSArray *viewModelArray;

// Not completely OK to keep this around, but we can guarantee we only ever want one on screen, so it's OK. 
@property (nonatomic, strong) TLHourSupplementaryView *hourSupplementaryView;

@end

@implementation TLEventViewController

#pragma mark - View Lifecycle Methods

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    EKEventManager *eventManager = [EKEventManager sharedInstance];
    
    RACSignal *newEventsSignal = [RACAbleWithStart(eventManager, events) deliverOn:[RACScheduler mainThreadScheduler]];
    
    RAC(self.viewModelArray) = [[[newEventsSignal distinctUntilChanged] map:^id(NSArray *eventsArray) {
        // First, sort the array first by size then by start time.
        
        NSArray *sortedArray = [eventsArray sortedArrayUsingComparator:^NSComparisonResult(EKEvent *obj1, EKEvent *obj2) {
            NSTimeInterval interval1 = [obj1.endDate timeIntervalSinceDate:obj1.startDate];
            NSTimeInterval interval2 = [obj2.endDate timeIntervalSinceDate:obj2.startDate];
            
            if (interval1 > interval2) {
                return NSOrderedAscending;
            }
            else if (interval1 < interval2) {
                return NSOrderedDescending;
            }
            else
            {
                if ([obj1.startDate isEarlierThanDate:obj2.startDate]) {
                    return NSOrderedAscending;
                }
                else if ([obj1.startDate isLaterThanDate:obj2.startDate]) {
                    return NSOrderedDescending;
                }
                else {
                    return NSOrderedSame;
                }
            }
        }];
        
        return sortedArray;
        
        // Then, create an array of TLEventViewModel objects based on that array.
    }] map:^id(NSArray *sortedEventArray) {
        NSMutableArray *mutableArray = [NSMutableArray arrayWithCapacity:sortedEventArray.count];
                
        for (EKEvent *event in sortedEventArray)
        {
            // Exclude all-day events
            if (event.isAllDay) continue;
            
            // Create our view model.
            TLEventViewModel *viewModel = [TLEventViewModel new];
            viewModel.event = event;
            viewModel.eventSpan = TLEventViewModelEventSpanFull;
            
            // Now determine if we're overlapping an existing event.
            // Note: this isn't that efficient, but our data sets are small enough to warrant an n^2 algorithm.
            for (TLEventViewModel *otherModel in mutableArray) {
                BOOL overlaps = [viewModel overlapsWith:otherModel];
                
                if (overlaps) {
                    if (otherModel.eventSpan == TLEventViewModelEventSpanTooManyWarning) {
                        otherModel.extraEventsCount++;
                        viewModel = nil;
                    }
                    else if (otherModel.eventSpan == TLEventViewModelEventSpanRight) {
                        // Now we need to determine if the viewModel can float to the left.
                        BOOL conflicts = NO;
                        
                        for (TLEventViewModel *possiblyConflictingModel in mutableArray) {
                            if (possiblyConflictingModel == otherModel) continue;
                            if (possiblyConflictingModel.eventSpan != TLEventViewModelEventSpanLeft) continue;
                            
                            if ([possiblyConflictingModel overlapsWith:viewModel]) {
                                conflicts = YES;
                                break;
                            }
                        }
                        
                        if (conflicts) {
                            otherModel.eventSpan = TLEventViewModelEventSpanTooManyWarning;
                            otherModel.extraEventsCount = 2;
                            viewModel = nil;
                        } else {
                            viewModel.eventSpan = TLEventViewModelEventSpanLeft;
                        }
                    }
                    else if (otherModel.eventSpan == TLEventViewModelEventSpanLeft) {
                        viewModel.eventSpan = TLEventViewModelEventSpanRight;
                    }
                    else if (otherModel.eventSpan == TLEventViewModelEventSpanFull)
                    {
                        otherModel.eventSpan = TLEventViewModelEventSpanLeft;
                        viewModel.eventSpan = TLEventViewModelEventSpanRight;
                    }
                }
            }
            
            if (viewModel) {
                [mutableArray addObject:viewModel];
            }
        }
        
        NSLog(@"Constructed array of %d events. ", mutableArray.count);
        
        return mutableArray;
    }];
    
    [RACAble(self.viewModelArray) subscribeNext:^(id x) {
        [self.collectionView reloadData];
        [self.collectionView.collectionViewLayout invalidateLayout];
    }];
    
    [self.collectionView registerNib:[UINib nibWithNibName:@"TLHourCell" bundle:nil] forCellWithReuseIdentifier:kCellIdentifier];
    [self.collectionView registerClass:[TLEventSupplementaryView class] forSupplementaryViewOfKind:[TLEventSupplementaryView kind] withReuseIdentifier:kEventSupplementaryViewIdentifier];
    [self.collectionView registerClass:[TLHourSupplementaryView class] forSupplementaryViewOfKind:[TLHourSupplementaryView kind] withReuseIdentifier:kHourSupplementaryViewIdentifier];
    
    self.touchDown = [[TLTouchDownGestureRecognizer alloc] initWithTarget:self action:@selector(touchDownHandler:)];
    self.touchDown.cancelsTouchesInView = NO;
    self.touchDown.delaysTouchesBegan = NO;
    self.touchDown.delaysTouchesEnded = NO;
    [self.collectionView addGestureRecognizer:self.touchDown];
    
    @weakify(self);
    [[[RACSignal interval:60.0f] deliverOn:[RACScheduler mainThreadScheduler]] subscribeNext:^(id x) {
        @strongify(self);
        [self updateBackgroundGradient];
    }];
}

-(void)viewDidAppear:(BOOL)animated
{
    [self.collectionView reloadData];
    [self updateBackgroundGradient];
}

- (void)viewWillAppear:(BOOL)animated {
    TLCollectionViewLayout *layout = [[TLCollectionViewLayout alloc] init];
    
    [self.collectionView setCollectionViewLayout:layout animated:animated];
    
    if (!self.backgroundGradientView)
    {
        self.backgroundGradientView = [[TLBackgroundGradientView alloc] initWithFrame:self.view.bounds];
        [self.view insertSubview:self.backgroundGradientView atIndex:0];
    }
}

#pragma mark - Gesture Recognizer Methods

- (void)touchDownHandler:(TLTouchDownGestureRecognizer *)recognizer {
    self.location = [recognizer locationInView:recognizer.view];
    
    EKEvent *event = [self eventUnderPoint:self.location];
    
    NSIndexPath *indexPath = [self.collectionView indexPathForItemAtPoint:self.location];    
    UICollectionViewLayoutAttributes *attributes = [self.collectionView.collectionViewLayout layoutAttributesForItemAtIndexPath:indexPath];
    NSInteger hour = indexPath.item;
    NSInteger minute = ((self.location.y - attributes.frame.origin.y) / attributes.size.height) * 60;
    
    // Convert from 24-hour format
    if (hour > 12) hour -= 12;
    if (hour == 0) hour += 12;
    if (minute < 0) minute = 0; // Weird rounding error
    
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        [self.collectionView performBatchUpdates:^{
            [self.backgroundGradientView setDarkened:YES];
            self.eventUnderFinger = nil;
            self.indexPathUnderFinger = indexPath;
            self.touch = YES;
            [self.delegate userDidBeginInteractingWithDayListViewController:self];
            if (CGRectContainsPoint(recognizer.view.bounds, self.location)) {
                [AppDelegate playTouchDownSound];
                [self.delegate userDidInteractWithDayListView:self updateTimeHour:hour minute:minute event:event];
            }
            
            for (NSInteger i = 0; i < 3; i++)
            {
                double delayInSeconds = i * 0.1;
                dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
                dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
                    [self.collectionView.collectionViewLayout invalidateLayout];
                });
            }
        } completion:^(BOOL finished) {
            [self.collectionView.collectionViewLayout invalidateLayout];
        }];
    } else if (recognizer.state == UIGestureRecognizerStateChanged) {
        [self.collectionView.collectionViewLayout invalidateLayout];
        
        if ([self.eventUnderFinger compareStartDateWithEvent:event] != NSOrderedSame ||
            (self.eventUnderFinger == nil && event != nil) ||
            (self.eventUnderFinger != nil && event == nil))
        {
            [AppDelegate playTouchNewEventSound];
            self.eventUnderFinger = event;
        }
        else
        {
            if ([indexPath compare:self.indexPathUnderFinger] != NSOrderedSame)
            {
                [AppDelegate playTouchNewHourSound];
                self.indexPathUnderFinger = indexPath;
            }
        }
        
        if (CGRectContainsPoint(recognizer.view.bounds, self.location)) {
            [self.delegate userDidInteractWithDayListView:self updateTimeHour:hour minute:minute event:event];
        }
    } else if (recognizer.state == UIGestureRecognizerStateEnded) {
        [self.collectionView performBatchUpdates:^{
            [self.backgroundGradientView setDarkened:NO];
            self.eventUnderFinger = nil;
            self.indexPathUnderFinger = nil;
            self.touch = NO;
            [self.delegate userDidEndInteractingWithDayListViewController:self];
            [AppDelegate playTouchUpSound];
            
            for (NSInteger i = 0; i < 3; i++)
            {
                double delayInSeconds = i * 0.1;
                dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
                dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
                    [self.collectionView.collectionViewLayout invalidateLayout];
                });
            }
        } completion:^(BOOL finished) {
            [self.collectionView.collectionViewLayout invalidateLayout];
        }];
    }
}

#pragma mark - TLCollectionViewLayoutDelegate Methods

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    TLHourCell *cell = (TLHourCell *)[collectionView cellForItemAtIndexPath:indexPath];
    
    // position sampled background image
    CGFloat yDistance = cell.maxY - cell.minY;
    CGFloat yDelta = cell.frame.origin.y - cell.minY;
    
    CGRect backgroundImageFrame = cell.backgroundImage.frame;
    backgroundImageFrame.origin.y = (cell.frame.size.height - backgroundImageFrame.size.height) * (yDelta / yDistance);
    cell.backgroundImage.frame = backgroundImageFrame;
    
    if (!self.touch) {
        // default size
        [UIView animateWithDuration:0.3 delay:0
                            options:UIViewAnimationOptionAllowUserInteraction|UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
                             cell.contentView.alpha = 0;
                         } completion:nil];
        return CGSizeMake(CGRectGetWidth(self.view.bounds), collectionView.frame.size.height / NUMBER_OF_ROWS);
    }
    
    CGFloat minSize = (collectionView.frame.size.height - (MAX_ROW_HEIGHT * EXPANDED_ROWS)) / 20;
    
    CGFloat dayLocation = (self.location.y / self.collectionView.frame.size.height) * 24;
    
    CGFloat effectiveHour = indexPath.item;
    
    CGFloat diff = dayLocation - effectiveHour;
    
    // prevent reducing size of min / max rows
    if (effectiveHour < EXPANDED_ROWS) {
        if (diff < 0) diff = 0;
    } else if (effectiveHour > NUMBER_OF_ROWS - EXPANDED_ROWS - 1) {
        if (diff > 0) diff = 0;
    }
    
    CGFloat delta = ((EXPANDED_ROWS - fabsf(diff)) / EXPANDED_ROWS);
    
    CGFloat size = (minSize + MAX_ROW_HEIGHT) * delta;
    
    cell.contentView.alpha = delta;
    
    if (size > MAX_ROW_HEIGHT) size = MAX_ROW_HEIGHT;
    if (size < minSize) size = minSize;
    
    return CGSizeMake(CGRectGetWidth(self.view.bounds), size);
}

-(CGRect)collectionView:(UICollectionView *)collectionView frameForHourViewInLayout:(TLCollectionViewLayout *)layout {
    
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDateComponents *components = [calendar components:NSHourCalendarUnit fromDate:[NSDate date]];
    
    NSInteger currentHour = components.hour;
    
    UICollectionViewLayoutAttributes *attributes = [self.collectionView.collectionViewLayout layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:currentHour inSection:0]];
    
    CGFloat viewHeight = attributes.size.height;
       
    return CGRectMake(0, attributes.frame.origin.y, CGRectGetWidth(self.view.bounds), viewHeight);
}

-(CGFloat)collectionView:(UICollectionView *)collectionView alphaForHourLineViewInLayout:(TLCollectionViewLayout *)layout {
    if (self.touch) {
        return 0.0f;
    }
    else {
        return 1.0f;
    }
}

-(CGFloat)collectionView:(UICollectionView *)collectionView hourProgressionForHourLineViewInLayout:(TLCollectionViewLayout *)layout{
    return 0.5f;
}

-(NSUInteger)collectionView:(UICollectionView *)collectionView numberOfEventSupplementaryViewsInLayout:(TLCollectionViewLayout *)layout {
    return self.viewModelArray.count;
}

-(CGRect)collectionView:(UICollectionView *)collectionView layout:(TLCollectionViewLayout *)layout frameForEventSupplementaryViewAtIndexPath:(NSIndexPath *)indexPath
{
    TLEventViewModel *model = self.viewModelArray[indexPath.item];
    
    CGFloat startY = 0;
    CGFloat endY = 0;
    CGFloat x;
    CGFloat width = CGRectGetWidth(self.view.bounds);
    
    // Grab the date components from the startDate and use the to find the hour and minutes of the event
    NSCalendar *currentCalendar = [NSCalendar currentCalendar];
    NSDateComponents *components = [currentCalendar components:NSHourCalendarUnit | NSMinuteCalendarUnit fromDate:model.event.startDate];
    NSInteger hour = components.hour;
    
    // Use the collection view's calculations for the hour cell representing the start hour, and adjust based on minutes if necessary
    UICollectionViewLayoutAttributes *startHourAttributes = [self.collectionView layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:hour inSection:0]];
    startY = CGRectGetMinY(startHourAttributes.frame);
    if (components.minute >= 30) {
        startY += CGRectGetHeight(startHourAttributes.frame) / 2.0f;
    }
    
    // Now grab the components of the end hour ...
    components = [currentCalendar components:NSHourCalendarUnit | NSMinuteCalendarUnit fromDate:model.event.endDate];
    hour = components.hour;
    
    // And do the same calculation for the max Y. 
    UICollectionViewLayoutAttributes *endHourAttributes = [self.collectionView layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:hour inSection:0]];
    endY = CGRectGetMinY(endHourAttributes.frame);
    if (components.minute >= 30)
    {
        endY += CGRectGetHeight(endHourAttributes.frame) / 2.0f;
    }
    
    // Finally, we need to calculate the X value and the width of the supplementary view. 
    if (model.eventSpan == TLEventViewModelEventSpanFull ||  model.eventSpan == TLEventViewModelEventSpanLeft) {
        x = 0;
    }
    else // implicitly, this is true: (model.eventSpan == TLEventViewModelEventSpanRight || model.eventSpan == TLEventViewModelEventSpanTooManyWarning)
    {
        x = CGRectGetMidX(self.view.bounds) + 1;
    }
    
    // All other event spans are half the horizontal size. 
    if (model.eventSpan != TLEventViewModelEventSpanFull)
    {
        width /= 2.0f;
    }
    
    return CGRectMake(x, startY, width, endY - startY);
}

#pragma mark - UICollectionViewDataSource Methods

-(NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return NUMBER_OF_ROWS;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    TLHourCell *cell = (TLHourCell *)[collectionView dequeueReusableCellWithReuseIdentifier:kCellIdentifier forIndexPath:indexPath];
    
    [self configureBackgroundCell:cell forIndexPath:indexPath];
    
    return cell;
}

-(UICollectionReusableView *)collectionView:(UICollectionView *)collectionView viewForSupplementaryElementOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)indexPath {
    if ([kind isEqualToString:[TLHourSupplementaryView kind]])
    {
        // We only ever have one hour supplementary view.
        if (!self.hourSupplementaryView)
        {
            self.hourSupplementaryView = [collectionView dequeueReusableSupplementaryViewOfKind:kind withReuseIdentifier:kHourSupplementaryViewIdentifier forIndexPath:indexPath];
            
            RACSubject *updateSubject = [RACSubject subject];
            
            NSCalendar *calendar = [NSCalendar currentCalendar];
            NSDateComponents *components = [calendar components:NSSecondCalendarUnit fromDate:[NSDate date]];
            
            NSInteger delay = 60 - components.second;
            
            NSLog(@"Scheduling subscription every minute for supplementary view in %d seconds", delay);
            
            double delayInSeconds = delay;
            dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
            dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
                
                NSLog(@"Creating initial subscription for supplementary view.");
                [updateSubject sendNext:[NSDate date]];
                
                [[RACSignal interval:60] subscribeNext:^(id x) {
                    NSLog(@"Updating minute of supplementary view.");
                    [updateSubject sendNext:x];
                }];
            });
            
            RAC(self.hourSupplementaryView.timeString) = [updateSubject map:^id(NSDate *date) {
                
                NSDateComponents *components = [calendar components:(NSHourCalendarUnit | NSMinuteCalendarUnit) fromDate:date];
                
                NSInteger hours = components.hour % 12;
                if (hours == 0) hours = 12;
                
                return [NSString stringWithFormat:@"%d:%02d", hours, components.minute];
            }];
            
            [updateSubject sendNext:[NSDate date]];
        }
        
        return self.hourSupplementaryView;
    } else {
        TLEventSupplementaryView *supplementaryView = [collectionView dequeueReusableSupplementaryViewOfKind:kind withReuseIdentifier:kEventSupplementaryViewIdentifier forIndexPath:indexPath];
        
        TLEventViewModel *model = self.viewModelArray[indexPath.item];
        supplementaryView.titleString = model.event.title;
        
        return supplementaryView;
    }
}


#pragma mark - Private Methods

-(void)updateBackgroundGradient {
    NSArray *events = [[EKEventManager sharedInstance] events];
    
    CGFloat soonestEvent = NSIntegerMax;
    for (EKEvent *event in events)
    {
        if (!event.isAllDay)
        {
            if ([event.startDate isEarlierThanDate:[NSDate date]] && ![event.endDate isEarlierThanDate:[NSDate date]])
            {
                // There's an event going on NOW.
                soonestEvent = 0;
            }
            else if (![event.startDate isEarlierThanDate:[NSDate date]])
            {
                NSTimeInterval interval = [event.startDate timeIntervalSinceNow];
                NSInteger numberOfMinutes = interval / 60;
                
                soonestEvent = MIN(soonestEvent, numberOfMinutes);
            }
        }
    }
    
    const CGFloat fadeTime = 30.0f;
    
    if (soonestEvent == 0)
    {
        [self.backgroundGradientView setAlertRatio:1.0f animated:YES];
    }
    else if (soonestEvent > fadeTime)
    {
        [self.backgroundGradientView setAlertRatio:0.0f animated:YES];
    }
    else
    {
        CGFloat ratio = (fadeTime - soonestEvent) / fadeTime;
        
        [self.backgroundGradientView setAlertRatio:ratio animated:YES];
    }
    
    // save copy of gradient as image
    TLAppDelegate *appDelegate = (TLAppDelegate *)[UIApplication sharedApplication].delegate;
    TLRootViewController *rootViewController = appDelegate.viewController;
    UIGraphicsBeginImageContext(self.backgroundGradientView.bounds.size);
    [self.backgroundGradientView.layer renderInContext:UIGraphicsGetCurrentContext()];
    rootViewController.gradientImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
}

-(EKEvent *)eventUnderPoint:(CGPoint)point
{    
    EKEvent *eventUnderTouch;
    
    for (NSInteger i = 0; i < self.viewModelArray.count; i++) {
        NSIndexPath *indexPath = [NSIndexPath indexPathForItem:i inSection:0];
        CGRect frame = [self collectionView:self.collectionView layout:(TLCollectionViewLayout *)self.collectionView.collectionViewLayout frameForEventSupplementaryViewAtIndexPath:indexPath];
        
        if (CGRectContainsPoint(frame, point)) {
            
            TLEventViewModel *model = self.viewModelArray[indexPath.item];
            
            if (model.eventSpan != TLEventViewModelEventSpanTooManyWarning) {
                eventUnderTouch = [self.viewModelArray[i] event];
            }
        }
    }
    
    return eventUnderTouch;
}

#pragma mark - Private Methods

-(void)configureBackgroundCell:(TLHourCell *)cell forIndexPath:(NSIndexPath *)indexPath{
}

@end
